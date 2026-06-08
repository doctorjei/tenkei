#!/usr/bin/env bash
#
# build-canopy — Derived image builder: yggdrasil minus init-family
#
# Canopy is a derived image. This script extracts the Yggdrasil .txz,
# chroots into it, purges the init-family (systemd pid1, udev daemon,
# dbus daemon, init meta-packages and their direct dependents), cleans
# up residual conffiles and unit directories, and re-packages as .txz
# / qcow2 / OCI.
#
# Audience: no-init process containers. Downstream consumers bring
# their own pid1 (tini, dumb-init, s6-overlay, etc.) or run as plain
# processes. Canopy keeps apt, bash, coreutils-via-busybox, and the
# shared-library floor (libsystemd0, libudev1, libpam*) — those can't
# be removed without breaking package management.
#
# Preconditions:
#   - build/yggdrasil-<VERSION>.txz must exist (from `rootfs/build-yggdrasil.sh`)
#
# Usage:
#   build-canopy.sh                         # build everything (reads VERSION)
#   build-canopy.sh 1.2.0                   # build for an explicit version
#   build-canopy.sh --no-txz                # skip .txz tarball
#   build-canopy.sh --no-qcow2              # skip .qcow2 disk image
#   build-canopy.sh --no-import             # skip OCI import
#
# Produces (by default):
#   - Tarball     build/canopy-<version>.txz
#   - Disk image  build/canopy-<version>.qcow2
#   - OCI image   canopy:<version> (in podman/docker)
#
# Requires: tar, unshare, chroot.
# Optional: qemu-img, mkfs.ext4 (for --qcow2), podman or docker (for --import).
#
# NOTE on /usr/lib/systemd/system residuals:
#   Some unit files under /usr/lib/systemd/system/ are owned by packages
#   that STAY installed (apt, e2fsprogs, util-linux, man-db). Our bulk
#   rm -rf removes them, leaving dpkg's ownership database inconsistent.
#   This is Option C from the canopy plan — accepted trade-off: the
#   files are dead weight without a pid1, and an irreversible purge
#   is appropriate for a no-init image. `yggdrasil-rehydrate.sh` is
#   NOT expected to produce a bootable systemd image when run on a
#   Canopy rootfs.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────
BUILD_DIR="$REPO_ROOT/build"
VERSION_FILE="$REPO_ROOT/VERSION"
DO_IMPORT=true
DO_TXZ=true
DO_QCOW2=true
VERSION_ARG=""

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

# ── Usage ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [VERSION]

Build the Canopy derived image from an existing Yggdrasil .txz.

Canopy = Yggdrasil minus the init-family. No systemd pid1, no udev
daemon, no dbus daemon, no init meta-packages. Shared-library floor
(libsystemd0, libudev1, libpam*) is kept — apt links against it.

Preconditions:
  build/yggdrasil-<VERSION>.txz must already exist. Run
  'bash rootfs/build-yggdrasil.sh' first if it does not.

Options:
      --no-import      Skip OCI import
      --no-txz         Skip .txz tarball output
      --no-qcow2       Skip .qcow2 disk image output
  -h, --help           Show help

Arguments:
  VERSION              Version string (default: read from VERSION file)

Requires: tar, unshare, chroot.
Optional: qemu-img, mkfs.ext4 (for --qcow2), podman/docker (for --import).
EOF
}

# ── Parse arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-import)     DO_IMPORT=false; shift ;;
        --no-txz)        DO_TXZ=false; shift ;;
        --no-qcow2)      DO_QCOW2=false; shift ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [[ -z "$VERSION_ARG" ]]; then
                VERSION_ARG="$1"; shift
            else
                echo "Error: unexpected argument: $1" >&2; usage >&2; exit 1
            fi
            ;;
    esac
done

# ── Version ─────────────────────────────────────────────────────────
if [[ -n "$VERSION_ARG" ]]; then
    VERSION="$VERSION_ARG"
else
    [[ -f "$VERSION_FILE" ]] || error "VERSION file not found: $VERSION_FILE"
    VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
fi
[[ -n "$VERSION" ]] || error "VERSION is empty"
IMAGE_TAG="canopy:$VERSION"

YGG_TXZ="$BUILD_DIR/yggdrasil-${VERSION}.txz"
CANOPY_TXZ="$BUILD_DIR/canopy-${VERSION}.txz"
CANOPY_QCOW2="$BUILD_DIR/canopy-${VERSION}.qcow2"

# ── Prerequisites ───────────────────────────────────────────────────
for tool in tar unshare chroot; do
    command -v "$tool" >/dev/null 2>&1 || error "missing required tool: $tool"
done

if $DO_QCOW2; then
    command -v qemu-img  >/dev/null 2>&1 || error "missing qemu-img (needed for --qcow2)"
    command -v mkfs.ext4 >/dev/null 2>&1 || error "missing mkfs.ext4 (needed for --qcow2)"
fi

detect_container_cmd() {
    if command -v podman &>/dev/null; then
        echo podman
    elif command -v docker &>/dev/null; then
        echo docker
    else
        echo ""
    fi
}

CONTAINER_CMD=""
if $DO_IMPORT; then
    CONTAINER_CMD=$(detect_container_cmd)
    if [[ -z "$CONTAINER_CMD" ]]; then
        warn "neither podman nor docker found — skipping OCI import"
        DO_IMPORT=false
    fi
fi

# ── Precondition: yggdrasil .txz must exist ──────────────────────
if [[ ! -f "$YGG_TXZ" ]]; then
    error "$YGG_TXZ not found.
Canopy is a derived image — it requires a Yggdrasil tarball as its
base. Run:

    bash rootfs/build-yggdrasil.sh

to produce build/yggdrasil-${VERSION}.txz first, then re-run this
script."
fi

# ── Cleanup ─────────────────────────────────────────────────────────
cleanup() {
    [[ -n "${WORK_DIR:-}" ]] && [[ -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null || true
    [[ -n "${SCRATCH:-}"  ]] && [[ -d "$SCRATCH"  ]] && rm -rf "$SCRATCH"  2>/dev/null || true
}
trap cleanup EXIT

# ── Stage scratch + work dirs ──────────────────────────────────────
SCRATCH=$(mktemp -d "/tmp/canopy-scratch.XXXXXX")
WORK_DIR=$(mktemp -d "/tmp/canopy-rootfs.XXXXXX")

mkdir -p "$BUILD_DIR"

IMPORT_TAR="$SCRATCH/import.tar"

# ── Stage strip script in SCRATCH ───────────────────────────────────
# Written as a standalone file outside the outer-heredoc expansion
# context, so $1/$2/$(...)/* are not expanded by the outer shell. The
# inner-phase.sh copies this into the chroot's /tmp before chroot'ing.
cat > "$SCRATCH/canopy-strip.sh" <<'STRIP_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# sudo's postrm refuses to remove itself unless this is set.
export SUDO_FORCE_REMOVE=yes

# Block maintainer-script service restarts (no running systemd in userns).
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

echo "Packages before purge: $(dpkg -l | grep '^ii' | wc -l)"

# Fresh lists for the purge solver.
apt-get update

# Helper: filter an input list down to only packages that are installed.
filter_installed() {
    local src="$1" dst="$2"
    : > "$dst"
    while read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if dpkg -s "$pkg" &>/dev/null; then echo "$pkg" >> "$dst"; fi
    done < "$src"
}

# Candidate purge list — direct strips + cascade drags named explicitly
# (defensive; apt would autoremove most of them, but naming them guards
# against apt being reticent about autoremove of "important" packages).
cat > /tmp/canopy-purge-candidates.txt <<'PURGELIST'
systemd
systemd-resolved
systemd-sysv
udev
dbus
dbus-bin
dbus-daemon
dbus-system-bus-common
dbus-session-bus-common
libkmod2
apparmor
libapparmor1
libnss-myhostname
init
init-system-helpers
sysvinit-utils
runit-helper
libpam-systemd
libdbus-1-3
initramfs-tools-bin
klibc-utils
libklibc
sudo
procps
ucf
uuid-runtime
openssh-client
openssh-server
openssh-sftp-server
tcpdump
libpcap0.8t64
PURGELIST

filter_installed /tmp/canopy-purge-candidates.txt /tmp/canopy-purge-installed.txt

echo "Packages to purge: $(wc -l < /tmp/canopy-purge-installed.txt)"
cat /tmp/canopy-purge-installed.txt

# Atomic purge. apt orders maintainer-script invocations correctly when
# given all names at once. Spike verified this works end-to-end; if a
# future package addition breaks it, split into two calls (cascade first,
# then init-family core) per the canopy plan's known-unknown #1.
if [[ -s /tmp/canopy-purge-installed.txt ]]; then
    xargs apt-get purge -y --allow-remove-essential \
        < /tmp/canopy-purge-installed.txt 2>&1 \
        | grep -v 'dpkg: warning: this is a protected package' || true
fi

apt-get autoremove --purge -y || true

apt-get clean
rm -rf /var/lib/apt/lists/*

# Provenance manifest — record the concrete list of packages actually
# purged (sorted + unique) for traceability.
mkdir -p /usr/share/canopy
sort -u /tmp/canopy-purge-installed.txt \
    > /usr/share/canopy/canopy-stripped.list

# Remove policy-rc.d blocker — runtime has no use for it.
rm -f /usr/sbin/policy-rc.d

echo "Packages after purge: $(dpkg -l | grep '^ii' | wc -l)"

rm -f /tmp/canopy-strip.sh /tmp/canopy-purge-candidates.txt /tmp/canopy-purge-installed.txt
STRIP_EOF

# ── Generate inner-phase.sh (runs inside unshare userns) ───────────
cat > "$SCRATCH/inner-phase.sh" <<INNER_EOF
#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$WORK_DIR"
SCRATCH="$SCRATCH"
VERSION="$VERSION"
BUILD_DIR="$BUILD_DIR"
YGG_TXZ="$YGG_TXZ"
CANOPY_TXZ="$CANOPY_TXZ"
CANOPY_QCOW2="$CANOPY_QCOW2"
IMPORT_TAR="$IMPORT_TAR"
DO_TXZ=$DO_TXZ
DO_QCOW2=$DO_QCOW2
DO_IMPORT=$DO_IMPORT

info()  { echo -e "\033[1;34m>>>\033[0m \$*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m \$*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m \$*" >&2; exit 1; }

info "[userns] uid=\$(id -u) euid=\$EUID"

# ── Extract yggdrasil .txz ─────────────────────────────────────────
info "Extracting \$YGG_TXZ..."
tar -xJf "\$YGG_TXZ" -C "\$WORK_DIR"
[[ -d "\$WORK_DIR/etc" && -d "\$WORK_DIR/usr" ]] || error "extraction did not yield a rootfs"

# ── Set up chroot (bind /proc /sys /dev) ───────────────────────────
info "Setting up chroot..."
mount --rbind /proc "\$WORK_DIR/proc"
mount --rbind /sys  "\$WORK_DIR/sys"
mount --rbind /dev  "\$WORK_DIR/dev"

rm -f "\$WORK_DIR/etc/resolv.conf"
cp /etc/resolv.conf "\$WORK_DIR/etc/resolv.conf"

# ── APT sandbox workaround for userns ──────────────────────────────
mkdir -p "\$WORK_DIR/etc/apt/apt.conf.d"
cat > "\$WORK_DIR/etc/apt/apt.conf.d/00userns-no-sandbox" <<'APTEOF'
APT::Sandbox::User "root";
Binary::apt::APT::Sandbox::User "root";
APTEOF

# ── Copy staged strip script into chroot ───────────────────────────
cp "\$SCRATCH/canopy-strip.sh" "\$WORK_DIR/tmp/canopy-strip.sh"
chmod +x "\$WORK_DIR/tmp/canopy-strip.sh"

info "Running canopy strip in chroot..."
chroot "\$WORK_DIR" /tmp/canopy-strip.sh

# ── Teardown chroot mounts ─────────────────────────────────────────
info "Tearing down chroot mounts..."
umount -l "\$WORK_DIR/dev"  2>/dev/null || true
umount -l "\$WORK_DIR/proc" 2>/dev/null || true
umount -l "\$WORK_DIR/sys"  2>/dev/null || true

# ── Post-purge filesystem cleanup ──────────────────────────────────
# dpkg leaves conffile dirs behind when it can't delete them (because
# they're non-empty or contain foreign files). Remove residuals:
info "Removing residual init/systemd directories..."
rm -rf "\$WORK_DIR/etc/systemd"
rm -rf "\$WORK_DIR/etc/init.d"
rm -rf "\$WORK_DIR/etc/rc0.d" "\$WORK_DIR/etc/rc1.d" "\$WORK_DIR/etc/rc2.d" \
       "\$WORK_DIR/etc/rc3.d" "\$WORK_DIR/etc/rc4.d" "\$WORK_DIR/etc/rc5.d" \
       "\$WORK_DIR/etc/rc6.d" "\$WORK_DIR/etc/rcS.d"
# Option C per canopy plan known-unknown #3: bulk-remove residual unit
# files. Some are owned by apt/e2fsprogs/util-linux/man-db (still
# installed), so dpkg's ownership DB will be inconsistent — accepted
# trade-off since there's no pid1 to read these files anyway.
rm -rf "\$WORK_DIR/usr/lib/systemd"
# deb-systemd-helper state (.dsh-also tracking files) references enable
# symlinks we just wiped under /etc|/usr/lib/systemd. Left behind, a
# downstream reinstall of a pkg whose unit canopy purged sees a stale
# .dsh-also, returns was-enabled=0, and takes the update-state branch
# instead of re-enabling the unit. No pid1 here, so none of this state
# is useful at runtime — wipe it with the rest of the systemd residue.
rm -rf "\$WORK_DIR/var/lib/systemd"
# Dangling init symlinks (owned by purged systemd-sysv / init packages).
rm -f "\$WORK_DIR/sbin/init" "\$WORK_DIR/usr/sbin/init"
# Drop the inherited resolv.conf symlink (target never materializes
# without pid1) and any systemd-resolved postinst .bak residue.
# Canopy ships without /etc/resolv.conf — consumers provide DNS.
rm -f "\$WORK_DIR/etc/resolv.conf" "\$WORK_DIR/etc/.resolv.conf.systemd-resolved.bak"

FINAL_SIZE=\$(du -sh "\$WORK_DIR" 2>/dev/null | awk '{print \$1}')
info "Final rootfs size: \$FINAL_SIZE"

# ── Artifacts ──────────────────────────────────────────────────────
if \$DO_IMPORT; then
    info "Writing intermediate tarball for OCI import..."
    tar -cf "\$IMPORT_TAR" -C "\$WORK_DIR" .
fi

if \$DO_TXZ; then
    info "Writing .txz artifact \$CANOPY_TXZ..."
    tar -cJf "\$CANOPY_TXZ" -C "\$WORK_DIR" .
    info "Tarball size: \$(du -h "\$CANOPY_TXZ" | awk '{print \$1}')"
fi

if \$DO_QCOW2; then
    info "Building qcow2 disk image \$CANOPY_QCOW2..."
    RAW_IMG=\$(mktemp "/tmp/canopy-raw.XXXXXX.raw")
    qemu-img create -f raw "\$RAW_IMG" 2G >/dev/null
    mkfs.ext4 -q -F -L canopy -d "\$WORK_DIR" "\$RAW_IMG"
    qemu-img convert -c -f raw -O qcow2 "\$RAW_IMG" "\$CANOPY_QCOW2"
    rm -f "\$RAW_IMG"
    info "qcow2 size: \$(du -h "\$CANOPY_QCOW2" | awk '{print \$1}')"
fi

echo "\$FINAL_SIZE" > "\$SCRATCH/final-size"
INNER_EOF
chmod +x "$SCRATCH/inner-phase.sh"

# ── Run inner phase inside user+mount namespace ─────────────────────
info "Entering user+mount namespace for chroot phase..."
unshare --user --mount --map-root-user bash "$SCRATCH/inner-phase.sh"

FINAL_SIZE=$(cat "$SCRATCH/final-size" 2>/dev/null || echo "unknown")

# ── OCI import (outside userns) ────────────────────────────────────
OCI_IMPORTED=false
if $DO_IMPORT; then
    info "Importing into $CONTAINER_CMD as $IMAGE_TAG..."
    # Expected failure path in kanibako (newuidmap limits on rootless
    # podman). Treat import as non-fatal so .txz + qcow2 remain the
    # usable primary artifacts in dev-container environments. CI runners
    # with working podman will succeed here and save the OCI archive
    # downstream (handled by the release workflow, not this script).
    if $CONTAINER_CMD import "$IMPORT_TAR" "$IMAGE_TAG"; then
        OCI_IMPORTED=true
        echo ""
        info "Image imported."
        $CONTAINER_CMD image inspect "$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null | \
            awk '{printf "Image size: %.0f MB\n", $1/1024/1024}' || true
    else
        warn "$CONTAINER_CMD import failed (see stderr above)."
        warn "This is expected in container build environments with restricted"
        warn "newuidmap, where rootless podman cannot complete import."
        warn "Elsewhere, check the stderr above for the cause."
        warn ".txz + qcow2 are still produced and are the primary artifacts."
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
info "canopy built successfully."
echo "  Source:      $YGG_TXZ"
echo "  Rootfs:      $FINAL_SIZE"
if $DO_TXZ;       then echo "  Tarball:     $CANOPY_TXZ"; fi
if $DO_QCOW2;     then echo "  qcow2:       $CANOPY_QCOW2"; fi
if $OCI_IMPORTED; then echo "  OCI:         $IMAGE_TAG ($CONTAINER_CMD)"; fi
