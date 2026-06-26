#!/usr/bin/env bash
#
# build-bootable-qcow2 — Self-booting "whole system" qcow2 builder
#
# Bakes a partition table, a GRUB (BIOS/SeaBIOS) bootloader, the kernel,
# the initramfs, and the rootfs into a single qcow2 disk image so a
# generic VM launcher boots it by just attaching the disk — no external
# `-kernel` / `-initrd` needed.
#
# Contrast with extract-oci.sh --qcow2, which produces a BARE single-ext4
# rootfs image (no partition table, no bootloader) that only boots when
# something external supplies the kernel. This script produces a disk you
# attach as the first virtio disk (-> /dev/vda) and boot directly.
#
# Usage:
#   build-bootable-qcow2.sh --rootfs <tar.xz|dir> --kernel <vmlinuz> \
#       --initramfs <img> --version <ver> --output <out.qcow2> \
#       [--size <GB>] [--label <ext4-label>]
#
# Options:
#   --rootfs <src>     Rootfs source. PREFERRED form is a .tar.xz / .txz
#                      tarball whose tar headers carry uid 0 ownership; the
#                      extraction runs under fakeroot so system files land
#                      owned by root. A pre-extracted directory is also
#                      accepted, but its on-disk ownership is used as-is.
#   --kernel <path>    Path to the kernel image (vmlinuz).
#   --initramfs <img>  Path to the initramfs image.
#   --version <ver>    Version string for labels/messages (e.g. 1.8.0-rc1).
#   --output <path>    Destination qcow2 path.
#   --size <GB>        Disk size in GB (default: rootfs size + 25% + 256
#                      MiB headroom, rounded up to whole GB, minimum 1).
#   --label <s>        ext4 filesystem label (default: gemet-root).
#   -h, --help         Show this help.
#
# In-guest boot contract (see initramfs/init): the baked grub.cfg passes
# `root=/dev/vda2 rootfstype=ext4`, which the initramfs parses and mounts
# before switch_root. No initramfs change is required.
#
# Algorithm:
#   1. Extract the rootfs into a scratch tree and measure it (du -sb).
#   2. Compute / honor the disk size, then truncate a raw image.
#   3. Partition with sgdisk: GPT + a 1 MiB EF02 BIOS-boot partition
#      (so SeaBIOS/GRUB can embed core.img) + an ext4 root partition.
#   4. In a SINGLE fakeroot session: extract the rootfs, stage the kernel,
#      initramfs, GRUB modules, and grub.cfg into /boot, then mke2fs -d
#      directly into partition 2 at its byte offset (no loop, no root).
#   5. Build core.img and install GRUB to the raw file with grub-bios-setup
#      (embeds into the EF02 partition, writes boot.img to the MBR gap).
#   6. Convert raw -> compressed qcow2.
#
# Requirements:
#   - grub-mkimage, grub-bios-setup     (apt install grub-pc-bin)
#   - /usr/lib/grub/i386-pc             (grub-pc-bin module dir)
#   - sgdisk                            (apt install gdisk)
#   - mke2fs                            (apt install e2fsprogs)
#   - qemu-img                          (apt install qemu-utils)
#   - fakeroot                          (apt install fakeroot)
#   - truncate, tar, xz                 (coreutils, tar, xz-utils)
#
set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: build-bootable-qcow2.sh --rootfs <tar.xz|dir> --kernel <vmlinuz> \
    --initramfs <img> --version <ver> --output <out.qcow2> \
    [--size <GB>] [--label <ext4-label>]

Bake a partition table + GRUB + kernel + initramfs + rootfs into a single
self-booting qcow2 (no external -kernel needed; attach as first virtio
disk -> /dev/vda).

Options:
  --rootfs <src>     Rootfs source. PREFERRED: a .tar.xz / .txz tarball
                     whose tar headers carry uid 0 ownership (extraction
                     runs under fakeroot so system files are root-owned).
                     A pre-extracted directory also works, but its on-disk
                     ownership is used verbatim — so unless it was extracted
                     as root/fakeroot, system files will be wrongly owned.
  --kernel <path>    Path to the kernel image (vmlinuz).
  --initramfs <img>  Path to the initramfs image.
  --version <ver>    Version string for labels/messages (e.g. 1.8.0-rc1).
  --output <path>    Destination qcow2 path.
  --size <GB>        Disk size in GB (default: rootfs + 25% + 256 MiB
                     headroom, rounded up to whole GB, minimum 1).
  --label <s>        ext4 filesystem label (default: gemet-root).
  -h, --help         Show this help.

Requires: grub-mkimage/grub-bios-setup (grub-pc-bin), sgdisk (gdisk),
mke2fs (e2fsprogs), qemu-img (qemu-utils), fakeroot, truncate, tar, xz,
and sudo + losetup (util-linux).

grub-bios-setup requires a real block device as its target (it rejects a
plain file: "DEVICE must be an OS device"). So this script always attaches
the raw image to a loop device and embeds GRUB against it — there is no
file-only path. The rootfs populate (fakeroot + mke2fs -d) is unprivileged;
only the loop attach + mount + grub-bios-setup need sudo.
USAGE
}

# ─── Parse arguments ──────────────────────────────────────────────
ROOTFS=""
KERNEL=""
INITRAMFS=""
VERSION=""
OUTPUT=""
SIZE_GB=""
LABEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs)     ROOTFS="$2";    shift 2 ;;
        --kernel)     KERNEL="$2";    shift 2 ;;
        --initramfs)  INITRAMFS="$2"; shift 2 ;;
        --version)    VERSION="$2";   shift 2 ;;
        --output)     OUTPUT="$2";    shift 2 ;;
        --size)       SIZE_GB="$2";   shift 2 ;;
        --label)      LABEL="$2";     shift 2 ;;
        --use-loop)   shift ;;  # accepted for back-compat; loop is always used now
        -h|--help)    usage; exit 0 ;;
        --)           shift; break ;;
        -*)           echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)            echo "Error: unexpected argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ -n "$ROOTFS"    ]] || { usage >&2; error "missing --rootfs"; }
[[ -n "$KERNEL"    ]] || { usage >&2; error "missing --kernel"; }
[[ -n "$INITRAMFS" ]] || { usage >&2; error "missing --initramfs"; }
[[ -n "$VERSION"   ]] || { usage >&2; error "missing --version"; }
[[ -n "$OUTPUT"    ]] || { usage >&2; error "missing --output"; }

[[ -e "$ROOTFS"    ]] || error "rootfs source not found: $ROOTFS"
[[ -f "$KERNEL"    ]] || error "kernel not found: $KERNEL"
[[ -f "$INITRAMFS" ]] || error "initramfs not found: $INITRAMFS"

# Classify the rootfs source: directory vs. tar.xz/txz tarball.
ROOTFS_KIND=""
if [[ -d "$ROOTFS" ]]; then
    ROOTFS_KIND="dir"
    warn "rootfs is a directory — its on-disk ownership is used as-is."
    warn "Unless it was extracted as root/fakeroot, system files will be"
    warn "wrongly owned. The .tar.xz / .txz form is recommended."
elif [[ -f "$ROOTFS" ]]; then
    case "$ROOTFS" in
        *.tar.xz|*.txz) ROOTFS_KIND="tar" ;;
        *) error "rootfs file must be a .tar.xz / .txz tarball: $ROOTFS" ;;
    esac
else
    error "rootfs source is neither a directory nor a regular file: $ROOTFS"
fi

# Default label.
[[ -n "$LABEL" ]] || LABEL="gemet-root"
# ext4 labels are limited to 16 bytes.
LABEL="${LABEL:0:16}"

if [[ -n "$SIZE_GB" ]]; then
    [[ "$SIZE_GB" =~ ^[0-9]+$ ]] || error "--size must be a positive integer GB"
    [[ "$SIZE_GB" -ge 1 ]]       || error "--size must be >= 1"
fi

# ─── Prerequisites ────────────────────────────────────────────────
GRUB_MODDIR="/usr/lib/grub/i386-pc"
[[ -d "$GRUB_MODDIR" ]] || \
    error "missing grub modules dir $GRUB_MODDIR (apt install grub-pc-bin)"

command -v grub-mkimage    >/dev/null 2>&1 || \
    error "missing grub-mkimage (apt install grub-pc-bin)"

# grub-bios-setup is shipped by grub-pc-bin under the module dir, and only
# lands on PATH (/usr/sbin) when grub2-common is also installed. Resolve it
# from PATH first, then fall back to the module dir so we depend on just
# grub-pc-bin.
GRUB_BIOS_SETUP="$(command -v grub-bios-setup 2>/dev/null || true)"
if [[ -z "$GRUB_BIOS_SETUP" ]]; then
    if [[ -x "$GRUB_MODDIR/grub-bios-setup" ]]; then
        GRUB_BIOS_SETUP="$GRUB_MODDIR/grub-bios-setup"
    else
        error "missing grub-bios-setup (apt install grub-pc-bin)"
    fi
fi

command -v sgdisk          >/dev/null 2>&1 || \
    error "missing sgdisk (apt install gdisk)"
command -v mke2fs          >/dev/null 2>&1 || \
    error "missing mke2fs (apt install e2fsprogs)"
command -v qemu-img        >/dev/null 2>&1 || \
    error "missing qemu-img (apt install qemu-utils)"
command -v fakeroot        >/dev/null 2>&1 || \
    error "missing fakeroot (apt install fakeroot)"
command -v truncate        >/dev/null 2>&1 || \
    error "missing truncate (apt install coreutils)"
command -v tar             >/dev/null 2>&1 || \
    error "missing tar (apt install tar)"
command -v xz              >/dev/null 2>&1 || \
    error "missing xz (apt install xz-utils)"

# ─── Loop prerequisites (always needed) ───────────────────────────
# grub-bios-setup requires a real block device, so we always attach the
# raw image to a loop device + mount its partition. Both need sudo.
command -v losetup >/dev/null 2>&1 || \
    error "missing losetup (apt install util-linux)"
sudo -n true 2>/dev/null || \
    error "this build needs passwordless sudo (loop attach + mount + grub-bios-setup)"
[[ -e /dev/loop-control ]] || \
    error "no /dev/loop-control — loop devices unavailable in this environment"

# ─── Cleanup ──────────────────────────────────────────────────────
SCRATCH=""
LOOPDEV=""
MOUNTED=""

cleanup() {
    [[ -n "$MOUNTED" ]] && sudo umount "$MOUNTED" 2>/dev/null || true
    [[ -n "$LOOPDEV" ]] && sudo losetup -d "$LOOPDEV" 2>/dev/null || true
    [[ -n "$SCRATCH" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT

# Honor TMPDIR so the scratch tree (extracted rootfs + sparse raw image)
# can be placed on a roomy disk-backed fs when /tmp is a small tmpfs.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/build-bootable-qcow2.XXXXXX")
RAW="$SCRATCH/disk.raw"
ROOTDIR="$SCRATCH/root"

# ─── Step 1: extract rootfs and measure it ────────────────────────
# We extract first so we can size the disk from the actual on-disk
# footprint, then partition, then populate. The real extraction (the one
# whose ownership matters) happens inside the fakeroot session in step 4;
# here we want a faithful size, so we extract under fakeroot too and reuse
# the tree. For the directory form we just measure it in place.
mkdir -p "$ROOTDIR"
if [[ "$ROOTFS_KIND" == "tar" ]]; then
    info "Extracting rootfs tarball for sizing (under fakeroot)..."
    # tar -p preserves perms; modern tar autodetects xz from the stream.
    fakeroot tar -xpf "$ROOTFS" -C "$ROOTDIR"
    MEASURE_DIR="$ROOTDIR"
else
    info "Measuring rootfs directory..."
    MEASURE_DIR="$ROOTFS"
fi

# Account for the kernel + initramfs + grub modules that also land in the
# filesystem; add their sizes to the rootfs footprint before headroom.
ROOTFS_BYTES=$(du -sb "$MEASURE_DIR" | awk '{print $1}')
KERNEL_BYTES=$(du -sb "$KERNEL" | awk '{print $1}')
INITRD_BYTES=$(du -sb "$INITRAMFS" | awk '{print $1}')
GRUBMOD_BYTES=$(du -sb "$GRUB_MODDIR" | awk '{print $1}')
CONTENT_BYTES=$(( ROOTFS_BYTES + KERNEL_BYTES + INITRD_BYTES + GRUBMOD_BYTES ))

# ─── Step 1b: resolve disk size in bytes ──────────────────────────
GIB=$(( 1024 * 1024 * 1024 ))
if [[ -n "$SIZE_GB" ]]; then
    DISK_BYTES=$(( SIZE_GB * GIB ))
    info "Using requested disk size: ${SIZE_GB}G"
else
    # content + 25% + 256 MiB headroom, rounded up to whole GB, min 1.
    HEADROOM=$(( 256 * 1024 * 1024 ))
    SIZED=$(( CONTENT_BYTES * 5 / 4 + HEADROOM ))
    SIZE_GB=$(( ( SIZED + GIB - 1 ) / GIB ))
    [[ "$SIZE_GB" -lt 1 ]] && SIZE_GB=1
    DISK_BYTES=$(( SIZE_GB * GIB ))
    info "Auto-sized disk: ${SIZE_GB}G (content $(numfmt --to=iec \
        "$CONTENT_BYTES" 2>/dev/null || echo "${CONTENT_BYTES}B"))"
fi

# ─── Step 2: allocate raw image ───────────────────────────────────
info "Allocating ${SIZE_GB}G raw image..."
truncate -s "$DISK_BYTES" "$RAW"

# ─── Step 3: partition (GPT + EF02 BIOS-boot + ext4 root) ─────────
info "Partitioning (GPT: EF02 BIOS-boot + ext4 root)..."
sgdisk -Z "$RAW" >/dev/null
sgdisk -a 2048 -n 1:2048:+1M -t 1:EF02 -c 1:"BIOS boot" "$RAW" >/dev/null
sgdisk -n 2:0:0 -t 2:8300 -c 2:"gemet root" "$RAW" >/dev/null

# Read partition 2's geometry back to compute its byte offset and size.
P2_INFO=$(sgdisk -i 2 "$RAW")
P2_FIRST_SECTOR=$(awk '/First sector:/ {print $3; exit}' <<<"$P2_INFO")
P2_SIZE_SECTORS=$(awk '/Partition size:/ {print $3; exit}' <<<"$P2_INFO")

[[ "$P2_FIRST_SECTOR" =~ ^[0-9]+$ ]] || \
    error "could not parse partition 2 first sector from sgdisk -i 2"
[[ "$P2_SIZE_SECTORS" =~ ^[0-9]+$ ]] || \
    error "could not parse partition 2 size from sgdisk -i 2"

P2_OFFSET_BYTES=$(( P2_FIRST_SECTOR * 512 ))
P2_SIZE_BYTES=$(( P2_SIZE_SECTORS * 512 ))
info "Root partition: offset ${P2_OFFSET_BYTES}B, size $(numfmt --to=iec \
    "$P2_SIZE_BYTES" 2>/dev/null || echo "${P2_SIZE_BYTES}B")"

# ─── Step 4/5: populate ext4 + boot files in one fakeroot session ─
# fakeroot's faked-ownership DB only spans a single invocation, so the
# rootfs extraction AND mke2fs must happen in the SAME fakeroot block. A
# directory extracted outside fakeroot would already have lost ownership.
# We export everything the inner block needs (fakeroot preserves env) and
# avoid heredoc interpolation pitfalls by referencing exported vars.
export ROOTFS ROOTFS_KIND ROOTDIR KERNEL INITRAMFS GRUB_MODDIR LABEL \
    VERSION RAW P2_OFFSET_BYTES P2_SIZE_BYTES

info "Populating ext4 root (label=$LABEL) under fakeroot..."
# Wrap in a brace group so the trailing `|| FAKEROOT_RC=$?` puts the whole
# invocation in a tested context (otherwise `set -e` would abort on a
# fakeroot failure before we could capture and report its exit code).
{
fakeroot bash <<'FAKEROOT'
set -euo pipefail

# For the tarball form, re-extract inside THIS fakeroot so the faked uid 0
# ownership is recorded in this session's DB. The earlier (sizing) extract
# was a throwaway under a different fakeroot session.
if [[ "$ROOTFS_KIND" == "tar" ]]; then
    rm -rf "$ROOTDIR"
    mkdir -p "$ROOTDIR"
    tar -xpf "$ROOTFS" -C "$ROOTDIR"
else
    # Directory form: ownership is whatever it is on disk (warn already
    # emitted). cp -a preserves it verbatim.
    rm -rf "$ROOTDIR"
    mkdir -p "$ROOTDIR"
    cp -a "$ROOTFS"/. "$ROOTDIR"/
fi

# Stage boot files into the rootfs tree so they land in the filesystem.
mkdir -p "$ROOTDIR/boot/grub"
cp "$KERNEL"    "$ROOTDIR/boot/vmlinuz"
cp "$INITRAMFS" "$ROOTDIR/boot/initramfs.img"
cp -r "$GRUB_MODDIR" "$ROOTDIR/boot/grub/"

cat > "$ROOTDIR/boot/grub/grub.cfg" <<GRUBCFG
set timeout=3
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console

menuentry "gemet bifrost ${VERSION}" {
    insmod part_gpt
    insmod ext2
    set root='hd0,gpt2'
    linux /boot/vmlinuz root=/dev/vda2 rootfstype=ext4 console=ttyS0,115200 console=tty0 rw
    initrd /boot/initramfs.img
}
GRUBCFG

# Build the ext4 directly into partition 2 at its byte offset. The size
# argument is REQUIRED and carries a unit suffix (k = KiB) so mke2fs does
# not misread it as a filesystem-block count; passing the partition size
# in KiB keeps the filesystem within the partition.
mke2fs -q -F -t ext4 -L "$LABEL" \
    -E offset="$P2_OFFSET_BYTES" \
    -d "$ROOTDIR" \
    "$RAW" "$(( P2_SIZE_BYTES / 1024 ))k"
FAKEROOT
# Capture the fakeroot exit status without `set -e` aborting first: the
# `|| FAKEROOT_RC=$?` keeps the pipeline in a tested context so a non-zero
# status lands in FAKEROOT_RC instead of killing the script silently.
FAKEROOT_RC=0
} || FAKEROOT_RC=$?
[[ "$FAKEROOT_RC" -eq 0 ]] || \
    error "fakeroot populate/mke2fs step failed (rc=$FAKEROOT_RC)"

# ─── Step 6: install GRUB to the raw file (no loop, no root) ──────
info "Building GRUB core.img and installing to disk..."
grub-mkimage -O i386-pc -p "(hd0,gpt2)/boot/grub" \
    -o "$SCRATCH/core.img" \
    part_gpt ext2 biosdisk normal configfile linux serial terminal echo \
    search search_label

cp "$GRUB_MODDIR/boot.img" "$SCRATCH/boot.img"

# grub-bios-setup reads the GPT, finds the EF02 BIOS-boot partition,
# embeds core.img there, and writes boot.img into the protective-MBR
# boot-code area.
# grub-bios-setup needs a real block device as its target AND it
# canonicalizes the backing device of its -d directory. A plain file
# fails everywhere ("DEVICE must be an OS device" / "guessing the root
# device failed" / "failed to get canonical path"). So: attach the raw to
# a loop device, MOUNT its ext4 partition (a real block device), and point
# -d at the grub dir on that mount. The ext4 was already populated
# unprivileged via mke2fs -E offset=; only this embed step needs sudo.
info "Attaching loop device + mounting partition for grub-bios-setup..."
LOOPDEV=$(sudo losetup -fP --show "$RAW")
[[ -n "$LOOPDEV" ]] || error "losetup failed to attach $RAW"
info "Loop device: $LOOPDEV"
MNT="$SCRATCH/mnt"
mkdir -p "$MNT"
sudo mount "${LOOPDEV}p2" "$MNT"
MOUNTED="$MNT"
# boot.img + core.img must live in the -d directory; the modules dir and
# grub.cfg are already baked into the ext4 at /boot/grub.
sudo cp "$SCRATCH/boot.img" "$SCRATCH/core.img" "$MNT/boot/grub/"
sudo "$GRUB_BIOS_SETUP" -d "$MNT/boot/grub" "$LOOPDEV"
sudo umount "$MNT"; MOUNTED=""
sudo losetup -d "$LOOPDEV"; LOOPDEV=""

# ─── Step 7: convert raw -> compressed qcow2 ──────────────────────
info "Converting raw → compressed qcow2 at $OUTPUT..."
qemu-img convert -c -f raw -O qcow2 "$RAW" "$OUTPUT"

# ─── Report ───────────────────────────────────────────────────────
info "Built bootable qcow2: $OUTPUT"
info "qcow2 size: $(du -h "$OUTPUT" 2>/dev/null | awk '{print $1}')"
info "Virtual disk size: ${SIZE_GB}G"
info "Boots with NO -kernel: attach as the first virtio disk -> /dev/vda."
