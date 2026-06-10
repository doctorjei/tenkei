# Gemet User Guide

## Overview

Gemet builds a minimal Linux kernel and initramfs purpose-built for booting
OCI container images as virtual machines. It replaces traditional VM disk images
with a virtiofs-mounted rootfs served directly from the host's Podman layer store.

Gemet is a subproject of [kento](https://github.com/doctorjei/kento) —
kento owns VM lifecycle (process management, networking, virtiofsd
supervision); Gemet provides the boot stack (kernel, initramfs, and
the rootfs variants that systemd and SSH compose on top of).
[droste](https://github.com/doctorjei/droste), the nested-virt test
image builder, is also a kento subproject and consumes Gemet's Canopy
base. Gemet releases independently; kento pulls its artifacts like any
other downstream consumer.

Pre-built artifacts (kernel, initramfs, Yggdrasil rootfs in multiple forms)
are attached to every tagged release, and OCI images are published to GHCR.
Most consumers pull pre-built artifacts rather than building locally — see
[releases.md](releases.md) for the artifact inventory and pull commands.
The rest of this guide walks through building from source.

## Components

### Kernel

Gemet uses the Kata Containers kernel configuration as a starting point — a
minimal kernel with just enough enabled for a guest VM:

- virtio drivers (PCI, net, console, block, SCSI)
- virtiofs (FUSE + virtio-fs)
- cgroups, namespaces, seccomp
- ext4/btrfs (for container workloads that expect them)
- No modules — everything built-in for single-image boot

The kernel configs live in `upstream/kernel/configs/fragments/`:
- `common/` — arch-independent fragments (virtio.conf, fs.conf, network.conf, etc.)
- `x86_64/` — x86_64-specific overrides

To build:

```bash
# Setup + build + install in one step (output goes to build/)
bash scripts/build-kernel.sh 6.18.15

# Or separately
bash scripts/build-kernel.sh 6.18.15 setup    # download source + apply patches
bash scripts/build-kernel.sh 6.18.15 build    # compile
bash scripts/build-kernel.sh 6.18.15 install  # copy vmlinuz + initramfs to build/
```

Output:
- `build/vmlinuz` -- compressed kernel (~7.5 MB)
- `build/gemet-initramfs.img` -- initramfs (~1.1 MB)

Requirements: build-essential, flex, bison, bc, libelf-dev, libssl-dev, busybox-static.

### Initramfs

Gemet replaces Kata's agent-based initramfs with a minimal one that:

1. Mounts the rootfs — virtiofs share or block device, selected by kernel cmdline
2. `mount --move`s `/dev /proc /sys` into the new root (so they survive the pivot)
3. Runs `switch_root -c /dev/console` to pivot into it (the `-c` reopens stdio on the new-root console so kernel messages keep flowing post-pivot)
4. Execs the init program (defaults to `/sbin/init`; overridable via `init=<path>` on the kernel cmdline, per kernel standard — e.g. `init=/bin/bash` for rescue)

The init script parses `root=`, `rootfstype=`, and `init=` from
`/proc/cmdline` and dispatches:

| cmdline                                 | behavior                                 |
|-----------------------------------------|------------------------------------------|
| `root=rootfs rootfstype=virtiofs`       | virtiofs (tag `rootfs`), dax=inode if supported (graceful fallback) |
| `root=/dev/vdaN rootfstype=ext4` (etc.) | block device (e.g. a qcow2 disk image)   |
| unset                                   | defaults to virtiofs (back-compat with kento) |
| `init=<path>`                           | exec `<path>` as pid1 after pivot (default `/sbin/init`) |

The block-device branch supports Yggdrasil's qcow2 artifact form: the disk
is a partition-less ext4 filesystem with no bootloader (the whole device
*is* the root filesystem — no partition table, no `/dev/vda1`); Gemet's
kernel + initramfs boot it externally via `qemu -kernel … -initrd …
-drive yggdrasil.qcow2 -append "root=/dev/vda rootfstype=ext4 …"`.

On boot-path failure, the init drops to `/bin/sh` (emergency shell) with
diagnostic output on the console. Three failure paths are handled:

- **rootfs mount failed** — the `root=` value or `rootfstype=` did not
  produce a mountable filesystem. The console prints the values it tried
  and hints at the likely cause (for virtiofs, the `tag=` mismatch is the
  common one).
- **`mount --move` failed** — the pseudo-fs move into the new root failed,
  which would cause a silent init hang post-pivot if uncaught. The console
  names which pseudo-fs failed and points at the likely cause (the target
  directory is missing on the rootfs).
- **`switch_root` exec failed** — `switch_root` returned rather than
  exec'd the init, which almost always means the `init=` path is missing
  or not executable inside the rootfs. The console prints the path it
  tried. (This is the failure class that caused the pre-v1.4.2 hang.)

Each of the three prints an actionable next step on-console and drops
to `/bin/sh` — there is no silent hang on the Gemet boot path.

**`init=` override.** Prior to v1.4.2, this argument was silently ignored
(init was hardcoded to `/sbin/init`). Since v1.4.2, it honors the
kernel-standard contract. Use this for rescue (`init=/bin/sh`,
`init=/bin/bash`) or bring-up diagnostics (`init=/some-diag-probe`).

To build:

```bash
bash initramfs/build.sh                              # default output
bash initramfs/build.sh /path/to/gemet-initramfs.img  # custom output path
```

Requirements: busybox-static (`apt install busybox-static`).
Packaged with busybox, the initramfs is about 1.1 MB.

### virtiofsd

The host-side component. `virtiofsd` shares a directory (the OCI rootfs) with
the guest VM over a Unix socket. QEMU connects the socket to a vhost-user-fs
device visible inside the guest.

```bash
# Share an OCI rootfs directory
virtiofsd \
    --socket-path=/tmp/vfs.sock \
    --shared-dir=/path/to/composed/rootfs
```

When used with kento, the rootfs is the same overlayfs composition of Podman
layers that kento uses for LXC containers.

## Usage

### Quick start

```bash
# 1. Build kernel + initramfs
bash scripts/build-kernel.sh 6.18.15

# 2. Create a test rootfs
sudo bash scripts/create-test-rootfs.sh /tmp/test-rootfs

# 3. Boot it (handles virtiofsd + QEMU + networking automatically)
sudo bash scripts/test-boot.sh \
    --kernel build/vmlinuz \
    --initrd build/gemet-initramfs.img \
    --rootfs /tmp/test-rootfs

# 4. SSH in from another terminal
ssh -p 2222 root@127.0.0.1
```

Press Ctrl-A X to exit QEMU.

### Manual boot (without test-boot.sh)

```bash
# 1. Compose the rootfs (using kento or manual overlayfs)
#    This produces a directory with the full container filesystem.

# 2. Start virtiofsd on the host (sudo may be needed if the rootfs is root-owned)
virtiofsd \
    --socket-path=/tmp/vfs.sock \
    --shared-dir=/path/to/rootfs &

# 3. Boot the VM
qemu-system-x86_64 \
    -kernel build/vmlinuz \
    -initrd build/gemet-initramfs.img \
    -m 512 -cpu host -enable-kvm \
    -chardev socket,id=vfs,path=/tmp/vfs.sock \
    -device vhost-user-fs-pci,chardev=vfs,tag=rootfs \
    -object memory-backend-memfd,id=mem,size=512M,share=on \
    -numa node,memdev=mem \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -append "console=ttyS0 rootfstype=virtiofs root=rootfs"
```

### Integration with kento

Kento provides full VM lifecycle management using Gemet's kernel and initramfs.
The OCI image must include `/boot/vmlinuz` and `/boot/initramfs.img` (typically
added by a [droste](https://github.com/doctorjei/droste) image layer, where droste
is the project's nested-virt VM image builder — or via a two-line compose
against `ghcr.io/doctorjei/gemet/boot:<ver>`, see below).

**Quick compose against Gemet's GHCR images.** The simplest path is to
stack the kernel image onto one of Gemet's rootfs images:

```dockerfile
FROM ghcr.io/doctorjei/gemet/boot:1.5.1 AS kernel
FROM ghcr.io/doctorjei/gemet/bifrost:1.5.1
COPY --from=kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=kernel /boot/initramfs.img /boot/initramfs.img
```

Swap `bifrost` for `yggdrasil` (no SSH layer) or `canopy` (no-init, for
downstream composition). Push the composed image to your own registry,
then hand it to `kento vm create --image <ref>`.

```bash
# Create a VM from an OCI image (--vm flag is required)
sudo kento container create docker.io/example/myimage --vm --name myvm --port 2222:22

# Start / stop / remove
sudo kento container start myvm
sudo kento container stop myvm
sudo kento container rm myvm

# List all containers (LXC and VM)
sudo kento container list
```

Kento handles everything automatically:
- Composes the OCI layers into an overlayfs rootfs
- Validates that `/boot/vmlinuz` and `/boot/initramfs.img` exist
- Starts virtiofsd to share the rootfs with the guest
- Launches QEMU/KVM with the correct virtiofs, networking, and console flags
- Tracks PIDs and cleans up on stop (virtiofsd, QEMU, mounts, sockets)

See the [kento VM mode docs](https://github.com/doctorjei/kento) for full details.

### Building VM-bootable OCI images

Kento expects the OCI image to contain Gemet's kernel and initramfs at
`/boot/vmlinuz` and `/boot/initramfs.img`. The
[droste](https://github.com/doctorjei/droste) project builds these images
using Containerfiles that copy Gemet's build output into the image and
configure the rootfs for VM boot.

A minimal VM-bootable Containerfile looks like:

```dockerfile
FROM debian:bookworm

# Install Gemet kernel + initramfs
COPY vmlinuz /boot/vmlinuz
COPY initramfs.img /boot/initramfs.img

# VM boot requirements
RUN > /etc/fstab \
    && echo 'root:password' | chpasswd \
    && apt-get update && apt-get install -y udev systemd-sysv \
    && mkdir -p /etc/systemd/network \
    && printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n' \
       > /etc/systemd/network/80-dhcp.network \
    && systemctl enable systemd-networkd
```

Key requirements for a VM-bootable image:
- `/boot/vmlinuz` and `/boot/initramfs.img` present
- Empty `/etc/fstab` (stale entries from base images hang on boot)
- A user account with a password set (locked accounts can't login via console)
- systemd-networkd with a DHCP `.network` file for virtio NICs. The
  match is narrowed to `Name=en* eth*` (primary NICs) rather than
  `Type=ether` so it never claims LXC/bridge veth interfaces. The gemet
  base images additionally ship a `10-lxc-veth-unmanaged.network`
  drop-in (`[Match] Name=veth*` / `[Link] Unmanaged=yes`) as a
  belt-and-braces guard when the image is used as an LXC host. The match
  is by name (`veth*`), not `Kind=veth`: inside an LXC *guest* the
  guest's own uplink `eth0` is itself a veth, so a `Kind` match would
  unmanage `eth0` and its address config would never apply — host-side
  bridge veths are named `veth*`, so this guards the LXC-host case
  without touching a guest's primary NIC.
- `udev` and `systemd-sysv` installed for full systemd boot

## Kernel as OCI image

Gemet also publishes its kernel + initramfs as a single-layer OCI image
(`ghcr.io/doctorjei/gemet/boot:<ver>`, built locally as
`localhost/gemet-kernel:<ver>`), a companion to the raw `build/` outputs.
Downstream VM images consume it via multi-stage `COPY --from=` instead of
staging the files next to the Containerfile.

See [kernel-as-oci](kernel-as-oci.md) for the Containerfile, build
commands, downstream pattern, and version compatibility notes.

## Yggdrasil (minimal Debian base)

Gemet publishes `yggdrasil:<ver>` — a minimal Debian 13 + systemd OCI
image intended as the foundation for downstream rootfs builds (droste
tiers, kento test fixtures, user-defined images). It ships in three
artifact forms: OCI image, `.txz` tarball (xz-compressed), and qcow2
disk image.

As of 1.2.0, the rootfs is ~210-230 MB (down from ~377 MB) thanks to a
multi-phase shrink pass applied at build time: BusyBox swap for 18
packages, targeted purges (`libc-l10n`, `file`, `libmagic*`, `locales`
after `locale-gen`), doc/info/man/locale sweep, and a 31-package
Python library trim.

### Recovery tooling

Two scripts ship inside the image at `/usr/share/yggdrasil/` with
symlinks in `/usr/local/bin/`, backed by build-time manifests
(`purged-packages.list`, `busybox-shim.manifest`, `wiped-dirs.list`):

- `yggdrasil-unshim <pkg>...` — removes BusyBox shim symlinks so a
  swapped package can be cleanly reinstalled. Also `--list` and `--all`.
- `yggdrasil-rehydrate` — one-shot full restoration: removes all
  shims, reinstalls every purged package, and
  `apt-get install --reinstall`'s the full package set to repopulate
  wiped `/usr/share/{doc,info,man,locale}`. 2-5 minutes. Supports
  `--dry-run`.

### Converting an OCI archive to other forms

`scripts/extract-oci.sh` is a pure-shell utility (no podman/umoci/root)
that reads any OCI image archive and re-emits its merged rootfs as a
directory, tarball, or bootable qcow2:

```bash
scripts/extract-oci.sh --dir   image.oci.tar /tmp/rootfs
scripts/extract-oci.sh --tar   image.oci.tar rootfs.tar
scripts/extract-oci.sh --qcow2 image.oci.tar rootfs.qcow2
```

Useful when you already have an OCI tarball (e.g.
`podman save --format=oci-archive yggdrasil:<ver> > yggdrasil.oci.tar`)
and want a disk image without re-running the full Yggdrasil build.

See [yggdrasil](yggdrasil.md) for the strip list, shrink phases, boot
contracts, SSH-key sync, and the canonical downstream-consumption
pattern.

## Bifrost (SSH-ready variant)

Gemet publishes `bifrost:<ver>` — Yggdrasil plus an opinionated SSH
layer for humans and ad-hoc testing. Bifrost re-enables
`ssh.service`, generates host keys at first boot via
`bifrost-hostkeys.service` (oneshot `ssh-keygen -A`,
`RemainAfterExit`), and ships `/etc/bifrost/authorized_keys` as a
staging path that `bifrost-sshkey-sync.service` merges into
`/root/.ssh/authorized_keys` non-destructively each boot.

No pre-generated `/etc/ssh/ssh_host_*_key` files are baked into the
published image — keys are always first-boot. Bifrost derives from
`yggdrasil-<ver>.txz` in ~30 s and ships the same three artifact
forms (tarball, qcow2, OCI). Size parity with Yggdrasil (~57 MB
tarball / 87 MB qcow2).

Use Bifrost when you want a VM you can SSH into out of the box.
Kento's E2E test fixtures compose on top of Bifrost for this reason.

See [bifrost](bifrost.md) for the full unit contracts, host-key
policy rationale, staging-path semantics, and key-rotation notes.

## Canopy (no-init variant)

Gemet publishes `canopy:<ver>` — Yggdrasil minus the init-family
(pid1, udev daemon, dbus daemon, init meta-packages). Canopy is
designed as an OCI base for no-init process containers: consumers
bring their own pid1 (tini, dumb-init, s6-overlay) or run as bare
processes. The qcow2 is intentionally not bootable as a standalone
VM — there is no pid1.

The tagline is "no pid1, no udev daemon, no dbus daemon" — not
"no systemd at all." A shared-library floor (`libsystemd0`,
`libsystemd-shared`, `libudev1`, `libpam0g*`) survives because apt
and util-linux link against it. Those libraries are inert without
their corresponding daemons running.

Canopy derives from `yggdrasil-<ver>.txz` in ~30 s, is ~10 MB
smaller than Yggdrasil under xz, and 29 packages lighter (211 →
182). The motivating downstream consumer is `droste-seed`, which
collapses to a pure Containerfile (`FROM canopy + useradd + sysctl`)
with no build script.

Note for downstream consumers: Canopy inherits Yggdrasil's busybox
shim — `apt install coreutils` silently lands real binaries at
`.distrib` paths, leaving the busybox shims in place. See the
["Rehydrating GNU tools"](canopy.md#rehydrating-gnu-tools) section
in the Canopy docs for the diversion-strip pattern that keeps
downstream postinsts from failing on GNU long-options.

See [canopy](canopy.md) for the strip list, shared-library floor
rationale, provenance manifest, residual-cleanup notes, and
downstream consumption patterns.

## Kernel Configuration

### Fragment system

Rather than maintaining monolithic `.config` files, Gemet uses the upstream
Kata fragment system. Each feature area has its own config snippet:

| Fragment | Purpose |
|---|---|
| `base.conf` | Core kernel options |
| `virtio.conf` | virtio bus, PCI, balloon |
| `virtio-extras.conf` | virtiofs, vsock, SCSI |
| `fs.conf` | Filesystem support |
| `network.conf` | Basic networking |
| `netfilter.conf` | iptables/nftables (for container networking) |
| `security.conf` | Security modules |
| `seccomp.conf` | Seccomp BPF |
| `cgroup.conf` | Control groups |
| `serial.conf` | Serial console |
| `dax.conf` | DAX direct access for virtiofs |
| `9p.conf` | 9p filesystem (fallback) |
| `debug.conf` | Debug options (optional) |

Fragments are merged by the build script into a final `.config`.

### Customizing

To add or remove kernel features:

1. Edit or add a fragment in `upstream/kernel/configs/fragments/common/`
2. For arch-specific options, use `upstream/kernel/configs/fragments/x86_64/`
3. Rebuild with `bash scripts/build-kernel.sh <version>`

## Troubleshooting

### VM doesn't boot
- Check that KVM is available: `ls /dev/kvm`
- Verify the kernel was built with virtiofs: `grep VIRTIO_FS .config`

### virtiofs mount fails inside VM
- Ensure `virtiofsd` is running on the host
- Check the socket path matches between virtiofsd and QEMU args
- Verify the kernel has CONFIG_VIRTIO_FS=y and CONFIG_FUSE_FS=y

### Slow boot
- Ensure `-enable-kvm` and `-cpu host` are passed to QEMU
- Check that the host CPU supports hardware virtualization

## DAX (Direct Access)

virtiofs supports DAX for memory-mapped file access, which bypasses the FUSE
request/response overhead. The Gemet kernel includes DAX support
(`CONFIG_FUSE_DAX=y`), and the initramfs mounts with `dax=inode` (per-inode
DAX, with graceful fallback when no DAX window is configured).

To enable DAX in test-boot.sh:

```bash
sudo bash scripts/test-boot.sh \
    --kernel build/vmlinuz \
    --initrd build/gemet-initramfs.img \
    --rootfs /tmp/test-rootfs \
    --dax          # 256M default cache window
    # or: --dax 512M  for a larger window
```

This adds a `cache-size` parameter to the QEMU virtiofs device and switches
virtiofsd to `--cache=always`. The DAX cache window is allocated from the VM's
shared memory region.

For manual QEMU invocations, add `cache-size=256M` to the device line:

```
-device vhost-user-fs-pci,chardev=vfs,tag=rootfs,cache-size=256M
```

DAX is not enabled by default. It adds memory overhead (the cache window is
reserved) but reduces latency for filesystem I/O.

## Architecture Support

Currently targeting x86_64 only. ARM64 support is possible using the upstream
Kata arm64 kernel fragments but is not yet tested.
