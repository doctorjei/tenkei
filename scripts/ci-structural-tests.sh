#!/usr/bin/env bash
#
# ci-structural-tests — Tier 1 (structural) release-artifact checks
#
# Runs unprivileged structural tests against a tenkei build/ directory
# (vmlinuz, initramfs, yggdrasil/bifrost/canopy tarballs + qcow2s +
# OCI archives, gemet-kernel OCI). Designed to run on a vanilla
# ubuntu-24.04 GitHub runner with no KVM, no root, no podman. All OCI
# inspection goes through scripts/extract-oci.sh (pure-shell extractor,
# already in the repo).
#
# Variant auto-detection:
#   The yggdrasil + gemet-kernel checks always run (they are required
#   artifacts for every tenkei release). The bifrost + canopy check
#   blocks auto-detect based on whether their .txz artifact exists
#   in --build-dir — so local partial builds (yggdrasil-only) still
#   run clean. CI always produces all three variants, so all checks
#   fire there.
#
# Usage:
#   ci-structural-tests.sh [--build-dir DIR] [--version VER] [-h|--help]
#
# Options:
#   --build-dir DIR    Directory containing build artifacts (default: ./build)
#   --version VER      Expected version string (default: read from ./VERSION)
#   -h, --help         Show this help
#
# Exit codes:
#   0   All checks passed (including variants that were auto-detected)
#   1   One or more checks failed
#   2   Usage error / missing prerequisite
#
# Note for local runs: the *-oci.tar files produced by `podman save` under
# sudo are sometimes root-owned. This script reads them as unprivileged
# (extract-oci.sh untars into a scratch dir), so as long as they are
# world-readable (chmod 644 *-oci.tar) this runs fine without sudo.
#
set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 2; }

pass()  { echo -e "\033[1;32m[PASS]\033[0m $*"; PASSED=$((PASSED + 1)); }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; FAILED=$((FAILED + 1)); }

usage() {
    cat <<'USAGE'
Usage: ci-structural-tests.sh [--build-dir DIR] [--version VER] [-h|--help]

Run Tier 1 (structural) release-candidate checks against a build/ dir.

Options:
  --build-dir DIR    Directory containing build artifacts (default: ./build)
  --version VER      Expected version string (default: read from ./VERSION)
  -h, --help         Show this help

Exit codes:
  0  all checks passed
  1  one or more checks failed
  2  usage error / missing prerequisite
USAGE
}

# ─── Parse arguments ──────────────────────────────────────────────
BUILD_DIR="./build"
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir)   BUILD_DIR="$2"; shift 2 ;;
        --build-dir=*) BUILD_DIR="${1#*=}"; shift ;;
        --version)     VERSION="$2"; shift 2 ;;
        --version=*)   VERSION="${1#*=}"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -d "$BUILD_DIR" ]] || error "build dir not found: $BUILD_DIR"

# Resolve to an absolute path so later operations are cwd-agnostic.
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)

if [[ -z "$VERSION" ]]; then
    if [[ -f "./VERSION" ]]; then
        VERSION=$(tr -d '[:space:]' < ./VERSION)
    else
        error "no --version given and ./VERSION not found"
    fi
fi

# ─── Locate helpers ───────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXTRACT_OCI="$SCRIPT_DIR/extract-oci.sh"
[[ -x "$EXTRACT_OCI" ]] || error "missing or non-executable: $EXTRACT_OCI"

# ─── Prerequisites ────────────────────────────────────────────────
for tool in tar jq file cpio xz qemu-img gunzip; do
    command -v "$tool" >/dev/null 2>&1 || \
        error "missing required tool: $tool"
done

# ─── Cleanup ──────────────────────────────────────────────────────
SCRATCH=""
cleanup() {
    [[ -n "$SCRATCH" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT

SCRATCH=$(mktemp -d "/tmp/ci-structural.XXXXXX")

PASSED=0
FAILED=0

info "Build dir: $BUILD_DIR"
info "Expected version: $VERSION"
echo ""

# ─── Check 1: VERSION file matches --version arg ──────────────────
info "Check 1: VERSION file matches expected version"
if [[ -f "./VERSION" ]]; then
    file_ver=$(tr -d '[:space:]' < ./VERSION)
    if [[ "$file_ver" == "$VERSION" ]]; then
        pass "VERSION file == $VERSION"
    else
        fail "VERSION file '$file_ver' != expected '$VERSION'"
    fi
else
    fail "./VERSION file not found"
fi
echo ""

# ─── Check 2: vmlinuz ─────────────────────────────────────────────
info "Check 2: vmlinuz"
VMLINUZ="$BUILD_DIR/vmlinuz"
if [[ ! -f "$VMLINUZ" ]]; then
    fail "vmlinuz not found at $VMLINUZ"
elif [[ ! -s "$VMLINUZ" ]]; then
    fail "vmlinuz is zero-length: $VMLINUZ"
else
    file_out=$(file -b "$VMLINUZ" || true)
    if [[ "$file_out" == *"Linux kernel"* ]]; then
        pass "vmlinuz exists, non-zero, bzImage magic ($(du -h "$VMLINUZ" | awk '{print $1}'))"
    else
        fail "vmlinuz does not look like a Linux kernel: $file_out"
    fi
fi
echo ""

# ─── Check 3: gemet-initramfs.img ────────────────────────────────
info "Check 3: gemet-initramfs.img"
INITRAMFS="$BUILD_DIR/gemet-initramfs.img"
if [[ ! -f "$INITRAMFS" ]]; then
    fail "initramfs not found at $INITRAMFS"
elif [[ ! -s "$INITRAMFS" ]]; then
    fail "initramfs is zero-length: $INITRAMFS"
else
    file_out=$(file -b "$INITRAMFS" || true)
    if [[ "$file_out" != *"gzip compressed"* ]]; then
        fail "initramfs is not gzip-compressed: $file_out"
    else
        # Extract to scratch and look for /init + /bin/busybox.
        INITRAMFS_DIR="$SCRATCH/initramfs"
        mkdir -p "$INITRAMFS_DIR"
        if ! ( cd "$INITRAMFS_DIR" && gunzip -c "$INITRAMFS" | cpio -idm --quiet ) 2>/dev/null; then
            fail "initramfs could not be extracted as gzip+cpio"
        else
            missing=""
            for f in init bin/busybox; do
                if [[ ! -f "$INITRAMFS_DIR/$f" ]]; then
                    missing+=" /$f"
                elif [[ ! -x "$INITRAMFS_DIR/$f" ]]; then
                    missing+=" /$f(not-executable)"
                fi
            done
            if [[ -n "$missing" ]]; then
                fail "initramfs missing/non-executable entries:$missing"
            else
                pass "initramfs exists, gzip+cpio, contains executable /init and /bin/busybox"
            fi
        fi
    fi
fi
echo ""

# ─── Check 4: yggdrasil-<ver>.txz ─────────────────────────────────
info "Check 4: yggdrasil-${VERSION}.txz"
TARXZ="$BUILD_DIR/yggdrasil-${VERSION}.txz"
if [[ ! -f "$TARXZ" ]]; then
    fail "tarball not found at $TARXZ"
elif [[ ! -s "$TARXZ" ]]; then
    fail "tarball is zero-length: $TARXZ"
else
    if ! tar -tJf "$TARXZ" >/dev/null 2>&1; then
        fail "tar -tJf failed — archive is corrupt or not a .txz"
    else
        # Read uncompressed size via xz --robot (machine-readable).
        uncompressed=$(xz -l --robot "$TARXZ" 2>/dev/null \
            | awk '$1=="totals"{print $5}')
        if [[ -z "$uncompressed" || ! "$uncompressed" =~ ^[0-9]+$ ]]; then
            fail "could not read uncompressed size from xz -l"
        else
            MB=$((uncompressed / 1024 / 1024))
            # Upper bound carries headroom for the retained apparmor
            # package (apparmor_parser kept for LXC 'generated'; +~3MB
            # uncompressed over the pre-A2 image).
            if (( MB >= 200 && MB <= 285 )); then
                pass ".txz OK, uncompressed ${MB} MB (within 200-285 MB)"
            else
                fail "uncompressed size ${MB} MB outside 200-285 MB bounds"
            fi
        fi
    fi
fi
echo ""

# ─── Check 5: yggdrasil-<ver>.qcow2 ───────────────────────────────
info "Check 5: yggdrasil-${VERSION}.qcow2"
QCOW2="$BUILD_DIR/yggdrasil-${VERSION}.qcow2"
if [[ ! -f "$QCOW2" ]]; then
    fail "qcow2 not found at $QCOW2"
elif [[ ! -s "$QCOW2" ]]; then
    fail "qcow2 is zero-length: $QCOW2"
else
    if qemu-img info "$QCOW2" >/dev/null 2>&1; then
        pass "qcow2 OK ($(du -h "$QCOW2" | awk '{print $1}'))"
    else
        fail "qemu-img info rejected $QCOW2"
    fi
fi
echo ""

# ─── Check 6: yggdrasil-<ver>-oci.tar ─────────────────────────────
info "Check 6: yggdrasil-${VERSION}-oci.tar"
YGG_OCI="$BUILD_DIR/yggdrasil-${VERSION}-oci.tar"
if [[ ! -f "$YGG_OCI" ]]; then
    fail "yggdrasil OCI archive not found at $YGG_OCI"
elif [[ ! -s "$YGG_OCI" ]]; then
    fail "yggdrasil OCI archive is zero-length: $YGG_OCI"
else
    YGG_ROOT="$SCRATCH/yggdrasil-rootfs"
    if ! "$EXTRACT_OCI" --dir "$YGG_OCI" "$YGG_ROOT" >/dev/null 2>&1; then
        fail "extract-oci.sh --dir failed on $YGG_OCI"
    else
        bad=""
        # /sbin/init (symlink OR regular file)
        if [[ ! -e "$YGG_ROOT/sbin/init" && ! -L "$YGG_ROOT/sbin/init" ]]; then
            bad+=" missing:/sbin/init"
        fi
        # /usr/bin/python3 (symlink OR regular file)
        if [[ ! -e "$YGG_ROOT/usr/bin/python3" && ! -L "$YGG_ROOT/usr/bin/python3" ]]; then
            bad+=" missing:/usr/bin/python3"
        fi
        # /etc/systemd/system/ populated (>= 5 entries)
        if [[ ! -d "$YGG_ROOT/etc/systemd/system" ]]; then
            bad+=" missing:/etc/systemd/system"
        else
            entries=$(find "$YGG_ROOT/etc/systemd/system" -mindepth 1 -maxdepth 1 | wc -l)
            if (( entries < 5 )); then
                bad+=" /etc/systemd/system-only-${entries}-entries"
            fi
        fi
        # /var/lib/dpkg/status parseable, >= 50 Package: lines, no half-installed
        DPKG_STATUS="$YGG_ROOT/var/lib/dpkg/status"
        if [[ ! -f "$DPKG_STATUS" ]]; then
            bad+=" missing:/var/lib/dpkg/status"
        else
            pkgs=$(grep -c '^Package:' "$DPKG_STATUS" 2>/dev/null || echo 0)
            if (( pkgs < 50 )); then
                bad+=" dpkg-status-only-${pkgs}-packages"
            fi
            # Any Status line that is not "install ok installed"?
            bad_statuses=$(awk '/^Status:/ && $0 != "Status: install ok installed"' \
                "$DPKG_STATUS" | head -5 || true)
            if [[ -n "$bad_statuses" ]]; then
                bad+=" half-installed-pkgs"
                warn "half-installed packages (first few):"
                awk '/^Package:/{p=$2} /^Status:/ && $0 != "Status: install ok installed"{print "    "p" -> "$0}' \
                    "$DPKG_STATUS" | head -10 >&2 || true
            fi
        fi

        # No loose busybox applet shims at the rootfs root. The
        # canonical-inversion fill-in must target /usr/bin/<applet>; a
        # symlink to busybox directly under / means the pre-1.7.0 bug
        # (applets laid at the rootfs root, off PATH) has regressed.
        # Legit merged-usr root symlinks (/bin, /sbin, /lib, ...) point
        # to usr/* directories, so -lname '*busybox' excludes them.
        loose=$(find "$YGG_ROOT" -maxdepth 1 -type l -lname '*busybox' \
            -printf '%f ' 2>/dev/null || true)
        if [[ -n "${loose// /}" ]]; then
            bad+=" loose-busybox-shims-at-root:${loose// /,}"
        fi

        if [[ -z "$bad" ]]; then
            pass "yggdrasil OCI structure OK (init, python3, systemd units, no loose root shims, dpkg clean: $pkgs pkgs)"
        else
            fail "yggdrasil OCI issues:$bad"
        fi
    fi
fi
echo ""

# ─── Check 7: gemet-boot-<ver>-oci.tar ─────────────────────────────
info "Check 7: gemet-boot-${VERSION}-oci.tar"
KERN_OCI="$BUILD_DIR/gemet-boot-${VERSION}-oci.tar"
if [[ ! -f "$KERN_OCI" ]]; then
    fail "kernel OCI archive not found at $KERN_OCI"
elif [[ ! -s "$KERN_OCI" ]]; then
    fail "kernel OCI archive is zero-length: $KERN_OCI"
else
    KERN_ROOT="$SCRATCH/kernel-rootfs"
    if ! "$EXTRACT_OCI" --dir "$KERN_OCI" "$KERN_ROOT" >/dev/null 2>&1; then
        fail "extract-oci.sh --dir failed on $KERN_OCI"
    else
        bad=""
        for f in boot/vmlinuz boot/initramfs.img; do
            if [[ ! -f "$KERN_ROOT/$f" ]]; then
                bad+=" missing:/$f"
            elif [[ ! -s "$KERN_ROOT/$f" ]]; then
                bad+=" zero-length:/$f"
            fi
        done
        if [[ -z "$bad" ]]; then
            pass "kernel OCI contains non-empty /boot/vmlinuz and /boot/initramfs.img"
        else
            fail "kernel OCI issues:$bad"
        fi
    fi
fi
echo ""

# ─── Bifrost variant (auto-detected) ──────────────────────────────
# Bifrost is a derived image (yggdrasil + SSH layer). On a CI runner all
# three artifacts (.txz, qcow2, -oci.tar) exist. In dev containers
# without working rootless podman (kanibako) the -oci.tar is skipped
# by the build script; we detect-via-.txz and then check the OCI
# block only when the archive is actually present.
BIFROST_TXZ="$BUILD_DIR/bifrost-${VERSION}.txz"
BIFROST_QCOW2="$BUILD_DIR/bifrost-${VERSION}.qcow2"
BIFROST_OCI="$BUILD_DIR/bifrost-${VERSION}-oci.tar"

if [[ ! -f "$BIFROST_TXZ" ]]; then
    info "Bifrost variant not detected ($BIFROST_TXZ absent) — skipping bifrost checks"
    echo ""
else
    info "Bifrost variant detected — running bifrost checks"
    echo ""

    # ─── Check 8: bifrost-<ver>.txz ───────────────────────────────
    info "Check 8: bifrost-${VERSION}.txz"
    if [[ ! -s "$BIFROST_TXZ" ]]; then
        fail "bifrost tarball is zero-length: $BIFROST_TXZ"
    elif ! tar -tJf "$BIFROST_TXZ" >/dev/null 2>&1; then
        fail "tar -tJf failed on bifrost tarball — corrupt or not a .txz"
    else
        # Uncompressed size band. Bifrost = Yggdrasil + a handful of tiny
        # overlay files, so the range tracks yggdrasil (200-280 MB) with a
        # small headroom bump.
        uncompressed=$(xz -l --robot "$BIFROST_TXZ" 2>/dev/null \
            | awk '$1=="totals"{print $5}')
        if [[ -z "$uncompressed" || ! "$uncompressed" =~ ^[0-9]+$ ]]; then
            fail "could not read uncompressed size from xz -l (bifrost)"
        else
            MB=$((uncompressed / 1024 / 1024))
            # Contents verification via tar listing (no extract needed).
            # We check:
            #   - /etc/systemd/system/bifrost-hostkeys.service        (unit file)
            #   - /etc/systemd/system/bifrost-sshkey-sync.service     (unit file)
            #   - /usr/local/sbin/bifrost-sync-sshkeys.sh             (sync script)
            #   - /etc/bifrost/                                       (staging dir)
            #   - multi-user.target.wants/bifrost-hostkeys.service    (wants symlink)
            #   - multi-user.target.wants/bifrost-sshkey-sync.service (wants symlink)
            #   - multi-user.target.wants/ssh.service                 (wants symlink)
            #   - sockets.target.wants/ssh.socket                     (wants symlink)
            # Tar entries for dirs end with /. Use sed-normalized list.
            LIST="$SCRATCH/bifrost-txz.list"
            tar -tJf "$BIFROST_TXZ" 2>/dev/null | sed 's:/$::' > "$LIST"

            bad=""
            for path in \
                etc/systemd/system/bifrost-hostkeys.service \
                etc/systemd/system/bifrost-sshkey-sync.service \
                usr/local/sbin/bifrost-sync-sshkeys.sh \
                etc/bifrost \
                etc/systemd/system/multi-user.target.wants/bifrost-hostkeys.service \
                etc/systemd/system/multi-user.target.wants/bifrost-sshkey-sync.service \
                etc/systemd/system/multi-user.target.wants/ssh.service \
                etc/systemd/system/sockets.target.wants/ssh.socket
            do
                if ! grep -Fxq "$path" "$LIST" && ! grep -Fxq "./$path" "$LIST"; then
                    bad+=" missing:/$path"
                fi
            done

            # Upper bound carries headroom for the retained apparmor
            # package inherited from yggdrasil (+~3MB uncompressed).
            if (( MB < 200 || MB > 295 )); then
                bad+=" size-${MB}MB-outside-200-295"
            fi

            if [[ -z "$bad" ]]; then
                pass "bifrost .txz OK, uncompressed ${MB} MB, 8 overlay paths present"
            else
                fail "bifrost .txz issues:$bad"
            fi
        fi
    fi
    echo ""

    # ─── Check 9: bifrost-<ver>.qcow2 ─────────────────────────────
    info "Check 9: bifrost-${VERSION}.qcow2"
    if [[ ! -f "$BIFROST_QCOW2" ]]; then
        fail "bifrost qcow2 not found at $BIFROST_QCOW2"
    elif [[ ! -s "$BIFROST_QCOW2" ]]; then
        fail "bifrost qcow2 is zero-length: $BIFROST_QCOW2"
    elif qemu-img info "$BIFROST_QCOW2" >/dev/null 2>&1; then
        pass "bifrost qcow2 OK ($(du -h "$BIFROST_QCOW2" | awk '{print $1}'))"
    else
        fail "qemu-img info rejected $BIFROST_QCOW2"
    fi
    echo ""

    # ─── Check 10: bifrost-<ver>-oci.tar ──────────────────────────
    info "Check 10: bifrost-${VERSION}-oci.tar"
    if [[ ! -f "$BIFROST_OCI" ]]; then
        # Not a hard fail locally; kanibako can't produce the OCI archive
        # (newuidmap limits). CI always produces it. We warn and skip.
        warn "bifrost OCI archive not present (expected when the build environment can't run rootless podman import)"
        echo "  skipped: $BIFROST_OCI"
    elif [[ ! -s "$BIFROST_OCI" ]]; then
        fail "bifrost OCI archive is zero-length: $BIFROST_OCI"
    else
        BIFROST_ROOT="$SCRATCH/bifrost-rootfs"
        if ! "$EXTRACT_OCI" --dir "$BIFROST_OCI" "$BIFROST_ROOT" >/dev/null 2>&1; then
            fail "extract-oci.sh --dir failed on $BIFROST_OCI"
        else
            bad=""
            # /sbin/init inherited from yggdrasil
            if [[ ! -e "$BIFROST_ROOT/sbin/init" && ! -L "$BIFROST_ROOT/sbin/init" ]]; then
                bad+=" missing:/sbin/init"
            fi
            # Bifrost overlay files
            for p in \
                etc/systemd/system/bifrost-hostkeys.service \
                etc/systemd/system/bifrost-sshkey-sync.service \
                usr/local/sbin/bifrost-sync-sshkeys.sh
            do
                if [[ ! -e "$BIFROST_ROOT/$p" && ! -L "$BIFROST_ROOT/$p" ]]; then
                    bad+=" missing:/$p"
                fi
            done
            # /etc/bifrost/ staging directory
            if [[ ! -d "$BIFROST_ROOT/etc/bifrost" ]]; then
                bad+=" missing:/etc/bifrost(dir)"
            fi
            # wants-symlinks (four of them)
            for w in \
                etc/systemd/system/multi-user.target.wants/bifrost-hostkeys.service \
                etc/systemd/system/multi-user.target.wants/bifrost-sshkey-sync.service \
                etc/systemd/system/multi-user.target.wants/ssh.service \
                etc/systemd/system/sockets.target.wants/ssh.socket
            do
                if [[ ! -L "$BIFROST_ROOT/$w" ]]; then
                    bad+=" missing-symlink:/$w"
                fi
            done

            if [[ -z "$bad" ]]; then
                pass "bifrost OCI structure OK (init, overlay units, /etc/bifrost, 4 wants symlinks)"
            else
                fail "bifrost OCI issues:$bad"
            fi
        fi
    fi
    echo ""
fi

# ─── Canopy variant (auto-detected) ───────────────────────────────
# Canopy is the no-init variant — init-family purged, shared-library
# floor kept. Key contract: /sbin/init, /etc/systemd/, and
# /usr/lib/systemd/ are all ABSENT. apt + bash must still work.
CANOPY_TXZ="$BUILD_DIR/canopy-${VERSION}.txz"
CANOPY_QCOW2="$BUILD_DIR/canopy-${VERSION}.qcow2"
CANOPY_OCI="$BUILD_DIR/canopy-${VERSION}-oci.tar"

if [[ ! -f "$CANOPY_TXZ" ]]; then
    info "Canopy variant not detected ($CANOPY_TXZ absent) — skipping canopy checks"
    echo ""
else
    info "Canopy variant detected — running canopy checks"
    echo ""

    # ─── Check 11: canopy-<ver>.txz ───────────────────────────────
    info "Check 11: canopy-${VERSION}.txz"
    if [[ ! -s "$CANOPY_TXZ" ]]; then
        fail "canopy tarball is zero-length: $CANOPY_TXZ"
    elif ! tar -tJf "$CANOPY_TXZ" >/dev/null 2>&1; then
        fail "tar -tJf failed on canopy tarball — corrupt or not a .txz"
    else
        uncompressed=$(xz -l --robot "$CANOPY_TXZ" 2>/dev/null \
            | awk '$1=="totals"{print $5}')
        if [[ -z "$uncompressed" || ! "$uncompressed" =~ ^[0-9]+$ ]]; then
            fail "could not read uncompressed size from xz -l (canopy)"
        else
            MB=$((uncompressed / 1024 / 1024))
            LIST="$SCRATCH/canopy-txz.list"
            tar -tJf "$CANOPY_TXZ" 2>/dev/null | sed 's:/$::' > "$LIST"

            bad=""
            # Required-present paths. Note: /bin and /sbin are symlinks
            # to /usr/bin and /usr/sbin in the yggdrasil base, so the
            # tar entry for bash lives at usr/bin/bash (not bin/bash).
            # Check the canonical path.
            for path in \
                usr/bin/apt \
                usr/bin/bash \
                usr/share/canopy/canopy-stripped.list
            do
                if ! grep -Fxq "$path" "$LIST" && ! grep -Fxq "./$path" "$LIST"; then
                    bad+=" missing:/$path"
                fi
            done
            # Required-absent paths (init-family is gone). /sbin/init +
            # /usr/sbin/init were explicit symlinks in yggdrasil; both
            # are removed in canopy. Also check the two systemd unit dirs
            # (the build script bulk-rm's /etc/systemd and /usr/lib/systemd).
            for path in \
                sbin/init \
                usr/sbin/init \
                etc/systemd \
                usr/lib/systemd
            do
                # Any listing whose normalized path begins with $path (or ./$path)
                # is considered present. grep -E pattern anchored to start-of-line.
                if grep -Eq "^(\./)?${path}(/|$)" "$LIST"; then
                    bad+=" unexpected-present:/$path"
                fi
            done

            # Canopy size band is smaller than yggdrasil (no init-family).
            if (( MB < 170 || MB > 240 )); then
                bad+=" size-${MB}MB-outside-170-240"
            fi

            # dpkg package count via selective extract of var/lib/dpkg/status.
            # Accept either "var/lib/dpkg/status" or "./var/lib/dpkg/status"
            # tar entry form.
            DPKG_EXTRACT="$SCRATCH/canopy-dpkg"
            mkdir -p "$DPKG_EXTRACT"
            if tar -xJf "$CANOPY_TXZ" -C "$DPKG_EXTRACT" \
                    ./var/lib/dpkg/status 2>/dev/null \
                || tar -xJf "$CANOPY_TXZ" -C "$DPKG_EXTRACT" \
                    var/lib/dpkg/status 2>/dev/null; then
                STATUS_FILE="$DPKG_EXTRACT/var/lib/dpkg/status"
                if [[ -f "$STATUS_FILE" ]]; then
                    pkgs=$(grep -c '^Package:' "$STATUS_FILE" 2>/dev/null || echo 0)
                    # Canopy spike produced 187 (pre-1.6.0); v1.6.1 lands
                    # near 196 after the python keep-list + EXTRA_INSTALL
                    # additions. 180-205 gives modest headroom while still
                    # catching catastrophic creep.
                    if (( pkgs < 180 || pkgs > 205 )); then
                        bad+=" dpkg-count-${pkgs}-outside-180-205"
                    fi
                else
                    bad+=" dpkg-status-not-extracted"
                fi
            else
                bad+=" dpkg-status-extract-failed"
                pkgs="?"
            fi

            if [[ -z "$bad" ]]; then
                pass "canopy .txz OK, uncompressed ${MB} MB, ${pkgs} pkgs, init-family absent"
            else
                fail "canopy .txz issues:$bad"
            fi
        fi
    fi
    echo ""

    # ─── Check 12: canopy-<ver>.qcow2 ─────────────────────────────
    info "Check 12: canopy-${VERSION}.qcow2"
    if [[ ! -f "$CANOPY_QCOW2" ]]; then
        fail "canopy qcow2 not found at $CANOPY_QCOW2"
    elif [[ ! -s "$CANOPY_QCOW2" ]]; then
        fail "canopy qcow2 is zero-length: $CANOPY_QCOW2"
    elif qemu-img info "$CANOPY_QCOW2" >/dev/null 2>&1; then
        pass "canopy qcow2 OK ($(du -h "$CANOPY_QCOW2" | awk '{print $1}'))"
    else
        fail "qemu-img info rejected $CANOPY_QCOW2"
    fi
    echo ""

    # ─── Check 13: canopy-<ver>-oci.tar ───────────────────────────
    info "Check 13: canopy-${VERSION}-oci.tar"
    if [[ ! -f "$CANOPY_OCI" ]]; then
        warn "canopy OCI archive not present (expected when the build environment can't run rootless podman import)"
        echo "  skipped: $CANOPY_OCI"
    elif [[ ! -s "$CANOPY_OCI" ]]; then
        fail "canopy OCI archive is zero-length: $CANOPY_OCI"
    else
        CANOPY_ROOT="$SCRATCH/canopy-rootfs"
        if ! "$EXTRACT_OCI" --dir "$CANOPY_OCI" "$CANOPY_ROOT" >/dev/null 2>&1; then
            fail "extract-oci.sh --dir failed on $CANOPY_OCI"
        else
            bad=""
            # Required-present
            for p in usr/bin/apt usr/bin/bash usr/share/canopy/canopy-stripped.list; do
                if [[ ! -e "$CANOPY_ROOT/$p" && ! -L "$CANOPY_ROOT/$p" ]]; then
                    bad+=" missing:/$p"
                fi
            done
            # Required-absent. Check the canonical /usr paths (since /bin
            # and /sbin are symlinks to /usr/bin and /usr/sbin, checking
            # via the symlink paths would traverse and give false positives
            # for any absence we assert).
            for p in usr/sbin/init etc/systemd usr/lib/systemd; do
                if [[ -e "$CANOPY_ROOT/$p" || -L "$CANOPY_ROOT/$p" ]]; then
                    bad+=" unexpected-present:/$p"
                fi
            done
            # dpkg count
            DPKG_STATUS="$CANOPY_ROOT/var/lib/dpkg/status"
            if [[ ! -f "$DPKG_STATUS" ]]; then
                bad+=" missing:/var/lib/dpkg/status"
            else
                pkgs=$(grep -c '^Package:' "$DPKG_STATUS" 2>/dev/null || echo 0)
                if (( pkgs < 180 || pkgs > 205 )); then
                    bad+=" dpkg-count-${pkgs}-outside-180-205"
                fi
            fi

            if [[ -z "$bad" ]]; then
                pass "canopy OCI structure OK (apt, bash, stripped.list; no init-family; ${pkgs} pkgs)"
            else
                fail "canopy OCI issues:$bad"
            fi
        fi
    fi
    echo ""
fi

# ─── Summary ──────────────────────────────────────────────────────
TOTAL=$((PASSED + FAILED))
echo "─────────────────────────────────────────────"
if (( FAILED == 0 )); then
    echo -e "\033[1;32m${PASSED} passed, ${FAILED} failed\033[0m (of $TOTAL checks)"
    exit 0
else
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (of $TOTAL checks)"
    exit 1
fi
