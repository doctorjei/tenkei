#!/usr/bin/env bash
#
# build-yggdrasil — Multi-phase rootfs shrink + OCI image build
#
# Downloads the Debian 13 genericcloud tar.xz, extracts the root partition
# via debugfs rdump (no nbd kernel module required), then runs a five-phase
# strip in a chroot before producing three artifact forms.
#
# Phases:
#   0. Kernel/boot purge + Yggdrasil-specific drop list (grub, cloud-init,
#      polkit, resolved/timesyncd, apparmor, vim, ...). Matches 1.1.0.
#   1. BusyBox swap: install busybox, repoint /bin/sh at bash, purge 18
#      packages (hostname/iputils-ping/gzip/cpio/sed/coreutils/grep/findutils/
#      diffutils/less/wget/kmod/netcat-openbsd/traceroute/fdisk/psmisc/
#      iproute2/dash), then `busybox --install -s` into a scratch dir and
#      mirror only to paths where nothing exists (exists-check naturally
#      protects kept packages).
#   2. Targeted purges: libc-l10n, file + libmagic1t64 + libmagic-mgc.
#      (locales is purged in 2b after locale-gen.)
#   3. Sweep trims: non-top-15 language dirs in /usr/share/locale and
#      /usr/share/man, wipe of /usr/share/doc and /usr/share/info,
#      apt cache + lists clean.
#   4. Python library purge: 31 python3-* packages with no non-Python
#      reverse deps. Keeps base interpreter.
#
# Recovery tooling ships inside the image at /usr/share/yggdrasil/ with
# symlinks in /usr/local/bin: `yggdrasil-unshim` (remove busybox shims) and
# `yggdrasil-rehydrate` (one-shot full restoration).
#
# Usage:
#   build-yggdrasil.sh                       # build everything
#   build-yggdrasil.sh --no-import           # skip OCI import
#   build-yggdrasil.sh --no-txz              # skip .txz tarball
#   build-yggdrasil.sh --no-qcow2            # skip .qcow2 disk image
#   build-yggdrasil.sh --no-shrink           # skip phases 1-4 (1.1.0-equivalent)
#
# Produces (by default):
#   - OCI image   yggdrasil:<version>
#   - Tarball     build/yggdrasil-<version>.txz
#   - Disk image  build/yggdrasil-<version>.qcow2
#
# Requires: fdisk, debugfs, tar, qemu-img, mkfs.ext4, curl, unshare.
# Optional: podman or docker (for --import).
#
# The chroot + artifact-writing block runs inside a user namespace via
# `unshare --user --mount --map-root-user`, so host root isn't required.
# apt is told to skip its privilege drop to _apt (which fails inside userns
# where only uid 0 is mapped) via an apt.conf.d drop-in.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────
BUILD_DIR="$REPO_ROOT/build"
DOWNLOAD_DIR="$BUILD_DIR/download"
SEED_TARGET="$REPO_ROOT/rootfs/seed-target.txt"
NETWORKD_CONF="$REPO_ROOT/rootfs/networkd/80-dhcp.network"
UNSHIM_SCRIPT="$REPO_ROOT/rootfs/yggdrasil-unshim.sh"
REHYDRATE_SCRIPT="$REPO_ROOT/rootfs/yggdrasil-rehydrate.sh"
VERSION_FILE="$REPO_ROOT/VERSION"
DO_IMPORT=true
DO_TXZ=true
DO_QCOW2=true
DO_SHRINK=true

TARXZ_URL="https://cloud.debian.org/images/cloud/trixie/latest"
TARXZ_FILE="debian-13-genericcloud-amd64.tar.xz"

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

# ── Version ─────────────────────────────────────────────────────────
[[ -f "$VERSION_FILE" ]] || error "VERSION file not found: $VERSION_FILE"
VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
[[ -n "$VERSION" ]] || error "VERSION file is empty"
IMAGE_TAG="yggdrasil:$VERSION"

# ── Package lists ───────────────────────────────────────────────────
PURGE_PACKAGES=(
    cloud-initramfs-growroot dracut-install grub-cloud-amd64 grub-common
    grub-efi-amd64-bin grub-efi-amd64-signed grub-efi-amd64-unsigned
    grub-pc-bin grub2-common libefiboot1t64 libefivar1t64 libfreetype6
    libnetplan1 libpng16-16t64 linux-image-cloud-amd64 linux-sysctl-defaults
    mokutil netplan-generator netplan.io os-prober pci.ids pciutils
    python3-netplan shim-helpers-amd64-signed shim-signed shim-signed-common
    shim-unsigned
)

YGGDRASIL_STRIP_PACKAGES=(
    cloud-init cloud-guest-utils cloud-image-utils cloud-utils polkitd
    libpolkit-agent-1-0 libpolkit-gobject-1-0
    systemd-timesyncd unattended-upgrades dmsetup apparmor screen qemu-utils
    dosfstools gdisk genisoimage dhcpcd-base reportbug python3-reportbug
    python3-debianbts apt-listchanges ssh-import-id bind9-host bind9-libs
    vim vim-common vim-runtime
)

BUSYBOX_SWAP_PACKAGES=(
    hostname iputils-ping gzip cpio sed coreutils grep findutils diffutils
    less wget kmod netcat-openbsd traceroute fdisk psmisc iproute2
)

PHASE2_PURGE_PACKAGES=(
    libc-l10n file libmagic1t64 libmagic-mgc
)

PHASE4_PURGE_PACKAGES=(
    python3-apt python3-attr python3-bcrypt python3-blinker
    python3-cffi-backend python3-chardet
    python3-configobj python3-cryptography python3-dbus python3-debconf
    python3-debian python3-distro python3-distro-info
    python3-json-pointer python3-jsonpatch python3-jsonschema
    python3-jsonschema-specifications python3-jwt
    python3-oauthlib python3-referencing python3-rpds-py
)

# Packages we want present in yggdrasil that are NOT in the Debian
# genericcloud baseline. seed-target.txt is a keep-list (apt-mark
# manual to defeat autoremove), not an install-list — items here
# are apt-get install'd explicitly during Phase 0.
EXTRA_INSTALL_PACKAGES=(
    python-is-python3
    python3-argcomplete
    python3-requests
)

# ── Usage ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build the Yggdrasil OCI base image from the Debian 13 genericcloud tar.xz.

Runs a five-phase rootfs shrink (phase 0 matches 1.1.0; phases 1-4 add
busybox swap, targeted purges, sweep trims, and python library purge),
then produces .txz / OCI / qcow2 artifacts.

Options:
      --no-import      Skip OCI import
      --no-txz         Skip .txz tarball output
      --no-qcow2       Skip .qcow2 disk image output
      --no-shrink      Skip phases 1-4 (1.1.0-equivalent image)
  -h, --help           Show help

Requires: fdisk, debugfs, tar, qemu-img, mkfs.ext4, curl, unshare.
Optional: podman or docker (for --import).
EOF
}

# ── Parse arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-import)     DO_IMPORT=false; shift ;;
        --no-txz)        DO_TXZ=false; shift ;;
        --no-qcow2)      DO_QCOW2=false; shift ;;
        --no-shrink)     DO_SHRINK=false; shift ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)               echo "Error: unexpected argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ── Prerequisites ───────────────────────────────────────────────────
for tool in fdisk debugfs tar curl sha512sum unshare; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        case "$tool" in
            fdisk)     pkg=fdisk ;;
            debugfs)   pkg=e2fsprogs ;;
            tar)       pkg=tar ;;
            curl)      pkg=curl ;;
            sha512sum) pkg=coreutils ;;
            unshare)   pkg=util-linux ;;
            *)         pkg="?" ;;
        esac
        error "missing required tool: $tool (apt install $pkg)"
    fi
done

if $DO_QCOW2; then
    command -v qemu-img  >/dev/null 2>&1 || error "missing qemu-img (needed for --qcow2; apt install qemu-utils)"
    command -v mkfs.ext4 >/dev/null 2>&1 || error "missing mkfs.ext4 (needed for --qcow2; apt install e2fsprogs)"
fi

[[ -f "$SEED_TARGET"   ]] || error "seed target list not found: $SEED_TARGET"
[[ -f "$NETWORKD_CONF" ]] || error "networkd config not found: $NETWORKD_CONF"

detect_container_cmd() {
    if command -v podman &>/dev/null; then
        echo podman
    elif command -v docker &>/dev/null; then
        echo docker
    else
        error "neither podman nor docker found"
    fi
}

if $DO_IMPORT; then
    CONTAINER_CMD=$(detect_container_cmd)
fi

# ── Cleanup ─────────────────────────────────────────────────────────
cleanup() {
    [[ -n "${WORK_DIR:-}" ]] && [[ -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null || true
    [[ -n "${SCRATCH:-}"  ]] && [[ -d "$SCRATCH"  ]] && rm -rf "$SCRATCH"  2>/dev/null || true
}
trap cleanup EXIT

# ── Download and verify tar.xz ─────────────────────────────────────
mkdir -p "$DOWNLOAD_DIR"

CACHED="$DOWNLOAD_DIR/$TARXZ_FILE"
if [[ -f "$CACHED" ]]; then
    info "Using cached download: $CACHED"
else
    info "Downloading $TARXZ_FILE..."
    curl -L --progress-bar -o "$CACHED.tmp" "$TARXZ_URL/$TARXZ_FILE"
    mv "$CACHED.tmp" "$CACHED"
fi

info "Verifying SHA512..."
EXPECTED_SHA=$(curl -sL "$TARXZ_URL/SHA512SUMS" \
    | grep "$TARXZ_FILE" | awk '{print $1}')
if [[ -z "$EXPECTED_SHA" ]]; then
    warn "could not fetch SHA512 checksum, skipping verification"
else
    ACTUAL_SHA=$(sha512sum "$CACHED" | awk '{print $1}')
    if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
        echo "  expected: $EXPECTED_SHA" >&2
        echo "  actual:   $ACTUAL_SHA" >&2
        rm -f "$CACHED"
        error "SHA512 mismatch"
    fi
    info "SHA512 verified."
fi

# ── Extract disk.raw, dd root partition, debugfs rdump ─────────────
SCRATCH=$(mktemp -d "/tmp/yggdrasil-scratch.XXXXXX")
WORK_DIR=$(mktemp -d "/tmp/yggdrasil-rootfs.XXXXXX")

info "Extracting disk.raw from tar.xz..."
tar -xJf "$CACHED" -C "$SCRATCH"
[[ -f "$SCRATCH/disk.raw" ]] || error "disk.raw not found in $TARXZ_FILE"

info "Parsing partition table..."
FDISK_OUT=$(fdisk -l "$SCRATCH/disk.raw")
ROOT_LINE=$(echo "$FDISK_OUT" | awk -v f="$SCRATCH/disk.raw" '$1==f"1"{print}')
if [[ -z "$ROOT_LINE" ]]; then
    echo "  fdisk output was:" >&2
    echo "$FDISK_OUT" | sed 's/^/    /' >&2
    error "could not find root partition (expected a row starting with '${SCRATCH}/disk.raw1')"
fi
ROOT_START_SEC=$(echo "$ROOT_LINE" | awk '{print $2}')
ROOT_SECTORS=$(echo "$ROOT_LINE" | awk '{print $4}')
[[ "$ROOT_START_SEC" =~ ^[0-9]+$ ]] || error "bad start sector '$ROOT_START_SEC' from fdisk row: $ROOT_LINE"
[[ "$ROOT_SECTORS" =~ ^[0-9]+$ ]]   || error "bad sector count '$ROOT_SECTORS' from fdisk row: $ROOT_LINE"
info "Root partition: start=$ROOT_START_SEC sectors=$ROOT_SECTORS"

ROOT_IMG="$SCRATCH/root.ext4"
info "Extracting root partition..."
dd if="$SCRATCH/disk.raw" of="$ROOT_IMG" bs=1M \
    iflag=skip_bytes,count_bytes \
    skip=$((ROOT_START_SEC * 512)) count=$((ROOT_SECTORS * 512)) status=none
FS_TYPE=$(blkid -o value -s TYPE "$ROOT_IMG" 2>/dev/null || true)
[[ "$FS_TYPE" =~ ^ext[234]$ ]] || error "unexpected fs type: $FS_TYPE"
rm -f "$SCRATCH/disk.raw"

MANIFEST="$SCRATCH/metadata.txt"
: > "$MANIFEST"
info "Walking image for SUID/SGID/non-root metadata..."
walk_image() {
    local dir="$1"
    debugfs -R "ls -l -p $dir" "$ROOT_IMG" 2>/dev/null | \
    while IFS=/ read -r _ inode mode uid gid name size _rest; do
        [[ -z "${name:-}" || "$name" == "." || "$name" == ".." ]] && continue
        local full
        if [[ "$dir" == "/" ]]; then full="/$name"; else full="$dir/$name"; fi
        local type="${mode:0:2}"
        local perm="${mode:2}"
        local special="${perm:0:1}"
        if [[ "$type" != "12" ]]; then
            if [[ "$special" != "0" || "$uid" != "0" || "$gid" != "0" ]]; then
                echo "$mode $uid $gid $full" >> "$MANIFEST"
            fi
        fi
        if [[ "$type" == "04" ]]; then
            walk_image "$full"
        fi
    done
}
walk_image "/"
info "Manifest: $(wc -l < "$MANIFEST") entries"

info "Extracting rootfs via debugfs rdump..."
debugfs -R "rdump / $WORK_DIR" "$ROOT_IMG" 2>&1 | tail -3
[[ -d "$WORK_DIR/etc" && -d "$WORK_DIR/usr" ]] || error "rdump did not produce a rootfs"

# ── Stage package lists + payload files in $SCRATCH ─────────────────
printf '%s\n' "${PURGE_PACKAGES[@]}"           > "$SCRATCH/purge-list.txt"
printf '%s\n' "${YGGDRASIL_STRIP_PACKAGES[@]}" > "$SCRATCH/ygg-strip-list.txt"
printf '%s\n' "${BUSYBOX_SWAP_PACKAGES[@]}"    > "$SCRATCH/busybox-swap-list.txt"
printf '%s\n' "${PHASE2_PURGE_PACKAGES[@]}"    > "$SCRATCH/phase2-purge-list.txt"
printf '%s\n' "${PHASE4_PURGE_PACKAGES[@]}"    > "$SCRATCH/phase4-purge-list.txt"
printf '%s\n' "${EXTRA_INSTALL_PACKAGES[@]}"   > "$SCRATCH/extra-install-list.txt"
grep -v '^#' "$SEED_TARGET" | grep -v '^$'     > "$SCRATCH/seed-keep.txt"
cp "$NETWORKD_CONF"                              "$SCRATCH/80-dhcp.network"

RECOVERY_STAGED=false
if [[ -f "$UNSHIM_SCRIPT" ]] && [[ -f "$REHYDRATE_SCRIPT" ]]; then
    cp "$UNSHIM_SCRIPT"    "$SCRATCH/yggdrasil-unshim.sh"
    cp "$REHYDRATE_SCRIPT" "$SCRATCH/yggdrasil-rehydrate.sh"
    RECOVERY_STAGED=true
fi

# ── Generate inner-phase.sh (runs inside unshare userns) ────────────
TXZ_PATH="$BUILD_DIR/yggdrasil-${VERSION}.txz"
QCOW2_PATH="$BUILD_DIR/yggdrasil-${VERSION}.qcow2"
IMPORT_TAR="$SCRATCH/import.tar"

cat > "$SCRATCH/inner-phase.sh" <<INNER_EOF
#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$WORK_DIR"
SCRATCH="$SCRATCH"
MANIFEST="$MANIFEST"
VERSION="$VERSION"
BUILD_DIR="$BUILD_DIR"
TXZ_PATH="$TXZ_PATH"
QCOW2_PATH="$QCOW2_PATH"
IMPORT_TAR="$IMPORT_TAR"
DO_SHRINK=$DO_SHRINK
DO_TXZ=$DO_TXZ
DO_QCOW2=$DO_QCOW2
DO_IMPORT=$DO_IMPORT
RECOVERY_STAGED=$RECOVERY_STAGED

info()  { echo -e "\033[1;34m>>>\033[0m \$*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m \$*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m \$*" >&2; exit 1; }

info "[userns] uid=\$(id -u) euid=\$EUID"

# ── Apply ownership + SUID/SGID fixups ──────────────────────────────
info "Applying ownership and SUID/SGID fixups..."
FIXUP_COUNT=0
while IFS=' ' read -r mode uid gid path; do
    [[ -z "\$path" ]] && continue
    target="\$WORK_DIR\$path"
    [[ -e "\$target" ]] || continue
    perm="\${mode:2}"
    chmod "0\$perm" "\$target" 2>/dev/null || true
    chown "\$uid:\$gid" "\$target" 2>/dev/null || true
    FIXUP_COUNT=\$((FIXUP_COUNT + 1))
done < "\$MANIFEST"
info "Applied \$FIXUP_COUNT fixups."

# ── Set up chroot (bind /proc /sys /dev) ────────────────────────────
info "Setting up chroot..."
mount --rbind /proc "\$WORK_DIR/proc"
mount --rbind /sys  "\$WORK_DIR/sys"
mount --rbind /dev  "\$WORK_DIR/dev"

rm -f "\$WORK_DIR/etc/resolv.conf"
cp /etc/resolv.conf "\$WORK_DIR/etc/resolv.conf"

# ── Write package lists into chroot ─────────────────────────────────
cp "\$SCRATCH/purge-list.txt"         "\$WORK_DIR/tmp/purge-list.txt"
cp "\$SCRATCH/ygg-strip-list.txt"     "\$WORK_DIR/tmp/ygg-strip-list.txt"
cp "\$SCRATCH/busybox-swap-list.txt"  "\$WORK_DIR/tmp/busybox-swap-list.txt"
cp "\$SCRATCH/phase2-purge-list.txt"  "\$WORK_DIR/tmp/phase2-purge-list.txt"
cp "\$SCRATCH/phase4-purge-list.txt"  "\$WORK_DIR/tmp/phase4-purge-list.txt"
cp "\$SCRATCH/extra-install-list.txt"  "\$WORK_DIR/tmp/extra-install-list.txt"
cp "\$SCRATCH/seed-keep.txt"          "\$WORK_DIR/tmp/seed-keep.txt"

# ── Generate + run strip script inside chroot ───────────────────────
cat > "\$WORK_DIR/tmp/strip.sh" <<'STRIP_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# APT sandbox workaround for userns: setgroups/seteuid to uid 42 (_apt)
# fails inside a namespace where only uid 0 is mapped.
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/00userns-no-sandbox <<'APTEOF'
APT::Sandbox::User "root";
Binary::apt::APT::Sandbox::User "root";
APTEOF

echo "Packages before strip: \$(dpkg -l | grep '^ii' | wc -l)"

printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

xargs apt-mark manual < /tmp/seed-keep.txt 2>/dev/null || true

dpkg-divert --local --rename --add /etc/kernel/postrm.d/zz-update-grub 2>/dev/null || true
rm -f /etc/kernel/postrm.d/zz-update-grub

filter_installed() {
    local src="\$1" dst="\$2"
    : > "\$dst"
    while read -r pkg; do
        [[ -z "\$pkg" ]] && continue
        if dpkg -s "\$pkg" &>/dev/null; then echo "\$pkg" >> "\$dst"; fi
    done < "\$src"
}

mkdir -p /usr/share/yggdrasil
: > /usr/share/yggdrasil/purged-packages.list

append_purged() { cat "\$1" >> /usr/share/yggdrasil/purged-packages.list; }

rm -rf /etc/grub.d /etc/default/grub.d /etc/kernel/postrm.d

echo "================================================================"
echo "  Phase 0: kernel/boot + Yggdrasil-specific strip"
echo "================================================================"

filter_installed /tmp/purge-list.txt     /tmp/purge-installed.txt
filter_installed /tmp/ygg-strip-list.txt /tmp/ygg-strip-installed.txt

if [[ -s /tmp/purge-installed.txt ]]; then
    append_purged /tmp/purge-installed.txt
    xargs apt-get purge -y --allow-remove-essential < /tmp/purge-installed.txt 2>&1 \
        | grep -v 'dpkg: warning: this is a protected package'
fi
apt-get autoremove -y || true

filter_installed /tmp/ygg-strip-installed.txt /tmp/ygg-strip-installed.txt.2
mv /tmp/ygg-strip-installed.txt.2 /tmp/ygg-strip-installed.txt

if [[ -s /tmp/ygg-strip-installed.txt ]]; then
    append_purged /tmp/ygg-strip-installed.txt
    xargs apt-get remove -y --purge < /tmp/ygg-strip-installed.txt 2>&1 \
        | grep -v 'dpkg: warning: this is a protected package'
fi
apt-get autoremove --purge -y || true

apt-get update
apt-get install -y --no-install-recommends vim-tiny nano

# Locale-gen MUST run while coreutils is still present (locales' postinst
# uses 'ln -r' which busybox ln doesn't support). Run locale-gen here, then
# Phase 2b can purge 'locales' safely afterward — the compiled archive at
# /usr/lib/locale/locale-archive is a generated file, not package-owned.
if ! dpkg -s locales >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends locales
fi
sed -i '/^# .*UTF-8/{
    /en_US\|zh_CN\|zh_TW\|hi_IN\|es_ES\|ar_SA\|fr_FR\|bn_IN\|pt_BR\|pt_PT\|id_ID\|ur_PK\|de_DE\|ja_JP\|ko_KR/s/^# //
}' /etc/locale.gen
locale-gen

# Install seed-target items that aren't in the genericcloud baseline.
# These won't show up via apt-mark manual alone (apt-mark only marks
# already-installed packages); they need an explicit install.
if [[ -s /tmp/extra-install-list.txt ]]; then
    xargs apt-get install -y --no-install-recommends < /tmp/extra-install-list.txt
fi

if [[ "\${DO_SHRINK_INNER}" != "true" ]]; then
    echo "--no-shrink: skipping phases 1-4"
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -f /usr/sbin/policy-rc.d
    echo "Packages after strip: \$(dpkg -l | grep '^ii' | wc -l)"
    exit 0
fi

# Phase 2b: purge locales now that locale-archive is generated. locale-gen
# creates /usr/lib/locale/locale-archive which is not package-owned, so it
# survives purge. Doing this BEFORE Phase 1 (busybox swap) so locales'
# postinst doesn't re-fire against a busybox'd environment.
echo "Purging locales package (post locale-gen)..."
echo locales >> /usr/share/yggdrasil/purged-packages.list
apt-get purge -y locales 2>&1 \
    | grep -v 'dpkg: warning: this is a protected package' || true
apt-get autoremove --purge -y || true

echo "================================================================"
echo "  Phase 1: busybox swap (18 packages + dash via bash-as-sh)"
echo "================================================================"

apt-get install -y --no-install-recommends busybox

# For every swap-package binary, dpkg-divert the original to .distrib and
# install a busybox (or bash, for /bin/sh) symlink at the original path.
# This keeps every binary path usable throughout the purge — dpkg's PATH
# check and maintainer-script commands (rm, mktemp, sed) resolve through
# our busybox shims even AFTER the owning package is removed. dpkg-divert
# records ensure the diverted .distrib file is cleaned up on purge.
: > /tmp/bb-shim-candidates.tsv
: > /usr/share/yggdrasil/busybox-shim.manifest
mkdir -p /usr/share/yggdrasil

divert_and_shim() {
    local pkg="\$1" path="\$2" link_target="\$3"
    # dpkg-divert won't divert a file to itself; use a per-file .distrib name
    dpkg-divert --local --rename --divert "\${path}.distrib" --add "\$path" \
        >/dev/null 2>&1 || return 0
    # Use busybox ln directly — /usr/bin/ln may have just been diverted.
    /usr/bin/busybox ln -sf "\$link_target" "\$path"
    printf '%s\t%s\n' "\$pkg" "\$path" >> /usr/share/yggdrasil/busybox-shim.manifest
}

BB_APPLETS=\$(busybox --list 2>/dev/null | tr '\n' ' ')

shim_package_binaries() {
    local pkg="\$1"
    dpkg -L "\$pkg" 2>/dev/null | while read -r path; do
        [[ -f "\$path" ]] || continue
        case "\$path" in
            /usr/bin/*|/bin/*|/usr/sbin/*|/sbin/*) ;;
            *) continue ;;
        esac
        # Parameter expansion — avoid basename since it may be diverted
        local base="\${path##*/}"
        # dash's sole binary is /bin/sh → bash; everything else → busybox
        if [[ "\$pkg" == "dash" && "\$base" == "sh" ]]; then
            divert_and_shim "\$pkg" "\$path" /usr/bin/bash
        else
            # Only shim if busybox has this applet (pre-cached list)
            case " \$BB_APPLETS " in
                *" \$base "*) divert_and_shim "\$pkg" "\$path" /usr/bin/busybox ;;
            esac
        fi
    done
}

echo "Diverting + shimming swap-package binaries (pre-purge)..."
while read -r pkg; do
    [[ -z "\$pkg" ]] && continue
    shim_package_binaries "\$pkg"
done < /tmp/busybox-swap-list.txt
shim_package_binaries dash
echo "Shim manifest: \$(wc -l < /usr/share/yggdrasil/busybox-shim.manifest) entries."

SWAP_LIST=\$(tr '\n' ' ' < /tmp/busybox-swap-list.txt)
append_purged /tmp/busybox-swap-list.txt
echo dash >> /usr/share/yggdrasil/purged-packages.list

# Purge everything (including dash) in one shot. Our shims are the live
# files at each path; dpkg removes the .distrib copies (the real binaries).
echo "Purging 18 swap packages + dash..."
apt-get purge -y --allow-remove-essential \$SWAP_LIST dash 2>&1 \
    | grep -v 'dpkg: warning: this is a protected package' || true
apt-get autoremove --purge -y || true

# Canonical-inversion: fill in any remaining empty busybox applet paths.
# busybox --install -s lays applets out flat in the stage dir, so each
# entry maps to /usr/bin/<applet> (on PATH; /usr/bin always exists). The
# [ -e ] guard then correctly skips applets already shimmed there.
BB_STAGE=\$(busybox mktemp -d /tmp/bb-stage.XXXXXX)
busybox --install -s "\$BB_STAGE"
: > /tmp/bb-extra-shims.txt
(cd "\$BB_STAGE" && busybox find . -type l) | while read -r rel; do
    target="/usr/bin/\$(busybox basename "\$rel")"
    [ -e "\$target" ] && continue
    ln -sf /usr/bin/busybox "\$target"
    echo "\$target" >> /tmp/bb-extra-shims.txt
done
rm -rf "\$BB_STAGE"
echo "Extra canonical shims installed: \$(wc -l < /tmp/bb-extra-shims.txt)."

echo "================================================================"
echo "  Phase 2a: targeted purges (libc-l10n, file, libmagic chain)"
echo "================================================================"

filter_installed /tmp/phase2-purge-list.txt /tmp/phase2-installed.txt
if [[ -s /tmp/phase2-installed.txt ]]; then
    append_purged /tmp/phase2-installed.txt
    xargs apt-get purge -y < /tmp/phase2-installed.txt 2>&1 \
        | grep -v 'dpkg: warning: this is a protected package' || true
fi
apt-get autoremove --purge -y || true

echo "================================================================"
echo "  Phase 4: python3-* library purge"
echo "================================================================"

filter_installed /tmp/phase4-purge-list.txt /tmp/phase4-installed.txt
if [[ -s /tmp/phase4-installed.txt ]]; then
    append_purged /tmp/phase4-installed.txt
    xargs apt-get purge -y < /tmp/phase4-installed.txt 2>&1 \
        | grep -v 'dpkg: warning: this is a protected package' || true
fi
apt-get autoremove --purge -y || true

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /usr/sbin/policy-rc.d

sort -u /usr/share/yggdrasil/purged-packages.list \
    > /usr/share/yggdrasil/purged-packages.list.tmp
mv /usr/share/yggdrasil/purged-packages.list.tmp \
    /usr/share/yggdrasil/purged-packages.list

echo "Packages after strip: \$(dpkg -l | grep '^ii' | wc -l)"
rm -f /tmp/strip.sh /tmp/*-list.txt /tmp/*-installed.txt /tmp/*-installed.txt.2 \
      /tmp/bb-shim-candidates.tsv /tmp/bb-shim-installed.txt
STRIP_EOF

# Substitute DO_SHRINK into strip.sh (uses placeholder inside)
sed -i "s/\\\${DO_SHRINK_INNER}/\$DO_SHRINK/g" "\$WORK_DIR/tmp/strip.sh"
chmod +x "\$WORK_DIR/tmp/strip.sh"

info "Running package strip in chroot..."
chroot "\$WORK_DIR" /tmp/strip.sh

# ── Stage networkd + recovery tooling ───────────────────────────────
info "Staging networkd DHCP config..."
install -D -m 0644 "\$SCRATCH/80-dhcp.network" \
    "\$WORK_DIR/etc/systemd/network/80-dhcp.network"

if \$RECOVERY_STAGED; then
    info "Staging recovery scripts..."
    install -d -m 0755 "\$WORK_DIR/usr/share/yggdrasil"
    install -D -m 0755 "\$SCRATCH/yggdrasil-unshim.sh" \
        "\$WORK_DIR/usr/share/yggdrasil/yggdrasil-unshim.sh"
    install -D -m 0755 "\$SCRATCH/yggdrasil-rehydrate.sh" \
        "\$WORK_DIR/usr/share/yggdrasil/yggdrasil-rehydrate.sh"
    install -d -m 0755 "\$WORK_DIR/usr/local/bin"
    ln -sf /usr/share/yggdrasil/yggdrasil-unshim.sh \
        "\$WORK_DIR/usr/local/bin/yggdrasil-unshim"
    ln -sf /usr/share/yggdrasil/yggdrasil-rehydrate.sh \
        "\$WORK_DIR/usr/local/bin/yggdrasil-rehydrate"
else
    warn "Recovery scripts missing — image ships without unshim/rehydrate."
fi

# ── Generate + run setup script (locales, unit enables, Phase 2b) ───
cat > "\$WORK_DIR/tmp/setup.sh" <<'SETUP_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service

# Yggdrasil is a pure base: it ships no SSH host keys (no cloud-init to
# generate them). Disable sshd by default so the unit doesn't fail on
# boot. Downstream tiers drop keys into /etc/ssh/ and re-enable via
# 'systemctl enable ssh'. See docs/yggdrasil.md.
systemctl disable ssh.service ssh.socket 2>/dev/null || true

# Locale generation and locales-package purge happen INSIDE strip.sh
# (before Phase 1) because locales postinst needs real coreutils ln -r.
:
SETUP_EOF

sed -i "s/\\\${DO_SHRINK_INNER}/\$DO_SHRINK/g" "\$WORK_DIR/tmp/setup.sh"
chmod +x "\$WORK_DIR/tmp/setup.sh"

info "Running per-image setup (locales, unit enables)..."
chroot "\$WORK_DIR" /tmp/setup.sh
rm -f "\$WORK_DIR/tmp/setup.sh"

# ── Teardown chroot ─────────────────────────────────────────────────
info "Tearing down chroot mounts..."
umount -l "\$WORK_DIR/dev"  2>/dev/null || true
umount -l "\$WORK_DIR/proc" 2>/dev/null || true
umount -l "\$WORK_DIR/sys"  2>/dev/null || true

rm -rf "\$WORK_DIR/boot/"* 2>/dev/null || true
rm -rf "\$WORK_DIR/lib/modules/"* 2>/dev/null || true

printf '# Empty — no block devices in OCI base\n' > "\$WORK_DIR/etc/fstab"

# Point /etc/resolv.conf at systemd-resolved's runtime stub. The target
# materializes when resolved starts on boot; -sfn replaces both the
# Debian default symlink and any leaked build-host resolv.conf copy.
ln -sfn /run/systemd/resolve/stub-resolv.conf "\$WORK_DIR/etc/resolv.conf"
rm -f "\$WORK_DIR/etc/.resolv.conf.systemd-resolved.bak"

# ── Phase 3: file-level sweep trims ─────────────────────────────────
if \$DO_SHRINK; then
    info "================================================================"
    info "  Phase 3: sweep trims (locale/man top-15, doc/info wipe, apt cache)"
    info "================================================================"

    if [[ -d "\$WORK_DIR/usr/share/locale" ]]; then
        SIZE_BEFORE=\$(du -sk "\$WORK_DIR/usr/share/locale" | awk '{print \$1}')
        find "\$WORK_DIR/usr/share/locale" -mindepth 1 -maxdepth 1 -type d \
            | while read -r d; do
                bn=\$(basename "\$d")
                if ! [[ "\$bn" =~ ^(en|zh|hi|es|ar|fr|bn|pt|id|ur|de|ja|ko)([_.]|\$) ]]; then
                    rm -rf "\$d"
                fi
              done
        SIZE_AFTER=\$(du -sk "\$WORK_DIR/usr/share/locale" | awk '{print \$1}')
        info "/usr/share/locale: \${SIZE_BEFORE}K -> \${SIZE_AFTER}K"
    fi

    if [[ -d "\$WORK_DIR/usr/share/man" ]]; then
        SIZE_BEFORE=\$(du -sk "\$WORK_DIR/usr/share/man" | awk '{print \$1}')
        find "\$WORK_DIR/usr/share/man" -mindepth 1 -maxdepth 1 -type d \
            | while read -r d; do
                bn=\$(basename "\$d")
                if [[ "\$bn" =~ ^man[0-9n]\$ ]]; then continue; fi
                if ! [[ "\$bn" =~ ^(en|zh|hi|es|ar|fr|bn|pt|id|ur|de|ja|ko)([_.]|\$) ]]; then
                    rm -rf "\$d"
                fi
              done
        SIZE_AFTER=\$(du -sk "\$WORK_DIR/usr/share/man" | awk '{print \$1}')
        info "/usr/share/man: \${SIZE_BEFORE}K -> \${SIZE_AFTER}K"
    fi

    if [[ -d "\$WORK_DIR/usr/share/doc" ]]; then
        SIZE_BEFORE=\$(du -sk "\$WORK_DIR/usr/share/doc" | awk '{print \$1}')
        rm -rf "\$WORK_DIR/usr/share/doc"/*
        info "/usr/share/doc wiped (was \${SIZE_BEFORE}K)"
    fi

    if [[ -d "\$WORK_DIR/usr/share/info" ]]; then
        SIZE_BEFORE=\$(du -sk "\$WORK_DIR/usr/share/info" | awk '{print \$1}')
        rm -rf "\$WORK_DIR/usr/share/info"/*
        info "/usr/share/info wiped (was \${SIZE_BEFORE}K)"
    fi

    rm -rf "\$WORK_DIR/var/lib/apt/lists"/* 2>/dev/null || true
    rm -rf "\$WORK_DIR/var/cache/apt/archives"/*.deb 2>/dev/null || true

    cat > "\$WORK_DIR/usr/share/yggdrasil/wiped-dirs.list" <<'WIPED_EOF'
/usr/share/doc
/usr/share/info
/usr/share/locale
/usr/share/man
WIPED_EOF
fi

FINAL_SIZE=\$(du -sh "\$WORK_DIR" 2>/dev/null | awk '{print \$1}')
info "Final rootfs size: \$FINAL_SIZE"

# ── Artifacts (inside userns to preserve root ownership in metadata) ─
# Write intermediate tar for OCI import (always, if DO_IMPORT, even when
# DO_TXZ is false). Use a consistent uncompressed stream.
if \$DO_IMPORT; then
    info "Writing intermediate tarball for OCI import..."
    tar -cf "\$IMPORT_TAR" -C "\$WORK_DIR" .
fi

if \$DO_TXZ; then
    info "Writing .txz artifact \$TXZ_PATH..."
    mkdir -p "\$BUILD_DIR"
    tar -cJf "\$TXZ_PATH" -C "\$WORK_DIR" .
    info "Tarball size: \$(du -h "\$TXZ_PATH" | awk '{print \$1}')"
fi

if \$DO_QCOW2; then
    info "Building qcow2 disk image \$QCOW2_PATH..."
    RAW_IMG=\$(mktemp "/tmp/yggdrasil-raw.XXXXXX.raw")
    qemu-img create -f raw "\$RAW_IMG" 2G >/dev/null
    mkfs.ext4 -q -F -L yggdrasil -d "\$WORK_DIR" "\$RAW_IMG"
    qemu-img convert -c -f raw -O qcow2 "\$RAW_IMG" "\$QCOW2_PATH"
    rm -f "\$RAW_IMG"
    info "qcow2 size: \$(du -h "\$QCOW2_PATH" | awk '{print \$1}')"
fi

echo "\$FINAL_SIZE" > "\$SCRATCH/final-size"
INNER_EOF
chmod +x "$SCRATCH/inner-phase.sh"

# ── Run inner phase inside user+mount namespace ─────────────────────
info "Entering user+mount namespace for chroot phase..."
unshare --user --mount --map-root-user bash "$SCRATCH/inner-phase.sh"

FINAL_SIZE=$(cat "$SCRATCH/final-size" 2>/dev/null || echo "unknown")

# ── OCI import (outside userns) ─────────────────────────────────────
if $DO_IMPORT; then
    info "Importing into $CONTAINER_CMD as $IMAGE_TAG..."
    $CONTAINER_CMD import "$IMPORT_TAR" "$IMAGE_TAG"
    echo ""
    info "Image imported."
    $CONTAINER_CMD image inspect "$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null | \
        awk '{printf "Image size: %.0f MB\n", $1/1024/1024}' || true
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
info "yggdrasil built successfully."
echo "  Source:   $TARXZ_FILE (genericcloud)"
if $DO_SHRINK; then
    echo "  Phases:   0 (kernel/boot + ygg-strip) + 1 (busybox) + 2 (purges) + 3 (sweeps) + 4 (python)"
else
    echo "  Phases:   0 (kernel/boot + ygg-strip) [--no-shrink]"
fi
echo "  Rootfs:   $FINAL_SIZE"
if $DO_IMPORT; then echo "  Image:    $IMAGE_TAG ($CONTAINER_CMD)"; fi
if $DO_TXZ;    then echo "  Tarball:  $TXZ_PATH"; fi
if $DO_QCOW2;  then echo "  qcow2:    $QCOW2_PATH"; fi
