# Gemet

**Boot OCI container images as real VMs — no disk images, no agent inside the guest.**

Gemet is the missing link between OCI images and lightweight VMs: a
stripped-down Linux kernel and initramfs that boots into a container
rootfs served over virtiofs from the host. No disk images, no image
conversion, no agent inside the guest — the same Podman layer store
that [kento](https://github.com/doctorjei/kento) uses for LXC
containers can also back full virtual machines.

Gemet is a subproject of [kento](https://github.com/doctorjei/kento)
— kento owns VM lifecycle; Gemet provides the boot stack.
[droste](https://github.com/doctorjei/droste), which ships
nested-virtualization test images built on Gemet's Canopy base, is
also a kento subproject. Gemet releases independently; kento pulls
its artifacts the same way any other consumer does.

## Quick Start

Grab the prebuilt kernel, initramfs, and a rootfs tarball from the
latest release and boot a Bifrost (SSH-ready) VM:

```bash
# 1. Download prebuilt artifacts (needs: gh CLI)
gh release download --repo doctorjei/gemet \
    --pattern 'vmlinuz' \
    --pattern 'gemet-initramfs.img' \
    --pattern 'bifrost-*.txz'

# 2. Unpack the rootfs
mkdir bifrost-rootfs && sudo tar -xJf bifrost-*.txz -C bifrost-rootfs

# 3. Clone this repo to pick up the boot-test helper
git clone https://github.com/doctorjei/gemet.git && cd gemet

# 4. Boot (needs: qemu-system-x86_64, virtiofsd, /dev/kvm access)
sudo bash scripts/test-boot.sh \
    --kernel ../vmlinuz \
    --initrd ../gemet-initramfs.img \
    --rootfs ../bifrost-rootfs

# 5. SSH in from another terminal
ssh -p 2222 root@127.0.0.1
```

To consume Gemet as OCI images in a multi-stage build (the pattern
[kento](https://github.com/doctorjei/kento) uses):

```dockerfile
FROM ghcr.io/doctorjei/gemet/boot:latest AS kernel
FROM ghcr.io/doctorjei/gemet/bifrost:latest
COPY --from=kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=kernel /boot/initramfs.img /boot/initramfs.img
```

See [docs/user-guide.md](docs/user-guide.md) for the full artifact
catalog, other variants (Yggdrasil foundation, Canopy no-init), and
usage patterns beyond the SSH happy path.

## How It Works

```
Host                              VM
+-----------------+    +--------------------+
|  Podman/Docker  |    |     gemet-boot     |
|   layer store   |    | (kernel+initramfs) |
|        |        |    |         |          |
|        v        |    |         v          |
|    virtiofsd ----------> virtiofs mount   |
| (shares rootfs) |    |         |          |
|                 |    |         v          |
|                 |    |    switch_root     |
|                 |    |         |          |
|                 |    |         v          |
|                 |    |     /sbin/init     |
+-----------------+    +--------------------+
```

1. **Host** runs `virtiofsd`, sharing the OCI rootfs (composed from Podman layers)
2. **QEMU/KVM** boots the Gemet kernel with the initramfs
3. **Initramfs** mounts the virtiofs share as the root filesystem
4. **`switch_root`** pivots into the container rootfs and execs `/sbin/init`

The VM boots in about 5 seconds with minimal memory overhead. The rootfs is shared
from the host -- no disk image to create, convert, or resize.

## Artifacts

Gemet produces two families of outputs. The raw files under `build/` are
the primary artifact; the OCI / tarball / qcow2 forms are additive, for
consumers that want referenceable artifact URLs or self-contained disk
images.

| Form     | Output                                | Details                                 |
|----------|---------------------------------------|-----------------------------------------|
| Raw      | `build/vmlinuz`                       | compressed kernel (~7.5 MB)             |
| Raw      | `build/gemet-initramfs.img`          | initramfs (~1.1 MB)                     |
| OCI      | `gemet-kernel:<ver>` (local) / `gemet/boot:<ver>` (GHCR) | kernel-as-OCI — see [docs/kernel-as-oci.md](docs/kernel-as-oci.md) |
| OCI      | `yggdrasil:<ver>`                     | minimal Debian 13 + systemd userland (~210-230 MB) — see [docs/yggdrasil.md](docs/yggdrasil.md) |
| OCI      | `bifrost:<ver>`                       | Yggdrasil + opinionated SSH layer — see [docs/bifrost.md](docs/bifrost.md) |
| OCI      | `canopy:<ver>`                        | Yggdrasil minus init-family (no-init base) — see [docs/canopy.md](docs/canopy.md) |
| Tarball  | `build/yggdrasil-<ver>.txz`           | Yggdrasil rootfs for `lxc-create` (xz-compressed; same on the release page) |
| Tarball  | `build/bifrost-<ver>.txz`             | Bifrost rootfs (SSH-ready)              |
| Tarball  | `build/canopy-<ver>.txz`              | Canopy rootfs (no-init)                 |
| qcow2    | `build/yggdrasil-<ver>.qcow2`         | bootable disk image for `qemu -drive`   |
| qcow2    | `build/bifrost-<ver>.qcow2`           | bootable disk image (SSH-ready)         |
| qcow2    | `build/canopy-<ver>.qcow2`            | disk image (no-init; primarily for inspection) |

As of 1.2.0, the Yggdrasil build applies a multi-phase shrink (BusyBox
swap, targeted purges, doc/locale/man sweep, python library trim) that
reduces the rootfs from ~377 MB down to ~210-230 MB. Recovery scripts
(`yggdrasil-unshim`, `yggdrasil-rehydrate`) ship inside the image for
downstream tiers that need any dropped package or wiped doc tree back —
see [docs/yggdrasil.md](docs/yggdrasil.md) for details.

**Yggdrasil vs Bifrost vs Canopy:** Yggdrasil is the pure foundation —
full systemd + networkd, no SSH host keys, sshd disabled, no
authorized_keys machinery. Each downstream consumer (droste tiers,
kento fixtures) layers its own user and authorized-keys policy on top.
**Bifrost** is the derived SSH-ready companion for humans and ad-hoc
testing: Yggdrasil plus sshd enabled, host keys generated at first
boot, and an `/etc/bifrost/authorized_keys` staging path for pre-boot
key injection. **Canopy** is the inverse shape — Yggdrasil with the
init-family removed (no systemd pid1, no udev daemon, no dbus daemon),
intended as a base for no-init process containers where the caller
brings their own pid1 (tini, dumb-init) or runs as a bare process. See
[docs/bifrost.md](docs/bifrost.md) and [docs/canopy.md](docs/canopy.md)
for the full contracts.

## Relationship to Kata Containers

Gemet borrows its kernel configs and build tooling from
[Kata Containers](https://github.com/kata-containers/kata-containers), but the
two projects solve different problems:

**What Kata does:**
- Full container runtime (`kata-runtime`) integrated with containerd/Kubernetes
- Runs a Go agent (`kata-agent`) inside the VM that receives gRPC commands
- The VM is a sandbox for OCI containers -- the host orchestrates everything

**What Gemet does:**
- No runtime, no agent, no containerd dependency
- The initramfs is a short shell script: mount virtiofs, switch_root, done
- The VM boots directly into the OCI image's own init -- it IS the machine
- Lifecycle management is handled by [kento](https://github.com/doctorjei/kento)

**What Gemet takes from Kata:**
- Kernel config fragments (virtio, virtiofs, networking, cgroups, etc.)
- Kernel patches for various versions
- The kernel build script (wrapped for standalone use)

**What Gemet replaces:**
- `kata-agent` -- replaced by a minimal shell init script
- `kata-runtime` -- replaced by kento's VM management
- containerd shim -- not needed; kento talks to QEMU directly

**Kernel relationship to Kata:** `scripts/build-kernel.sh` wraps Kata's
upstream builder and applies Kata's config fragments and patches as-is,
then layers a thin gemet-side config overlay (`kernel/config/<arch>/gemet.conf`)
on top via `merge_config.sh` + `make olddefconfig`. The overlay
currently adds `CONFIG_INPUT_EVDEV=y` so userspace receives ACPI events
(needed for `qm shutdown` on PVE and similar host-driven shutdowns —
Kata's vsock-based agent flow doesn't). Gemet `vmlinuz` is binary-
compatible with Kata's at the boot interface but no longer drop-in
identical with Kata's published binaries — the `.config` differs.

The upstream Kata code lives in `upstream/` as git subtrees. Changes to these
files are not committed — they are overwritten on the next upstream sync.
Gemet's own code wraps or overrides upstream behavior as needed. Local
customization (e.g., kernel config fragments) is fine for personal builds.

## Build from Source

```bash
# Build kernel + initramfs (output goes to build/)
bash scripts/build-kernel.sh 6.18.15
```

This downloads the kernel source, configures it with Kata's config fragments,
compiles it, builds the initramfs, and copies both to `build/`:

```
build/vmlinuz              -- compressed kernel (~7.5 MB)
build/gemet-initramfs.img -- initramfs (~1.1 MB)
```

Build dependencies (Debian/Ubuntu):
```bash
apt install build-essential flex bison bc libelf-dev libssl-dev busybox-static
```

Optional OCI artifacts: `bash scripts/build-kernel-oci.sh` packages the
kernel + initramfs as `gemet-kernel:<ver>` for downstream multi-stage
consumption, and `sudo bash rootfs/build-yggdrasil.sh` produces the
companion `yggdrasil:<ver>` minimal Debian userland. See
[docs/kernel-as-oci.md](docs/kernel-as-oci.md) and
[docs/yggdrasil.md](docs/yggdrasil.md).

### Boot-Test a Local Build

```bash
# 1. Create a test rootfs
sudo bash scripts/create-test-rootfs.sh /tmp/test-rootfs

# 2. Boot it
sudo bash scripts/test-boot.sh \
    --kernel build/vmlinuz \
    --initrd build/gemet-initramfs.img \
    --rootfs /tmp/test-rootfs

# 3. SSH in (from another terminal)
ssh -p 2222 root@127.0.0.1
```

The test script handles virtiofsd, QEMU, networking, and cleanup automatically.
Run `bash scripts/test-boot.sh --help` for all options.

## Project Structure

```
gemet/
+-- initramfs/
|   +-- init                 # Minimal virtiofs / block-dev mount + switch_root
|   +-- build.sh             # Packages initramfs (busybox + init)
+-- kernel/
|   +-- Containerfile        # kernel-as-OCI image source
+-- rootfs/
|   +-- build-yggdrasil.sh        # Yggdrasil OCI + .txz + qcow2 builder
|   +-- build-bifrost.sh          # Bifrost derived-image builder (yggdrasil + SSH layer)
|   +-- build-canopy.sh           # Canopy derived-image builder (yggdrasil minus init-family)
|   +-- seed-target.txt           # package keep-list
|   +-- networkd/                 # staged systemd-networkd config
|   +-- bifrost/                  # Bifrost overlay: units + authorized_keys sync script
+-- scripts/
|   +-- build-kernel.sh           # Kernel build wrapper (setup/build/install)
|   +-- build-kernel-oci.sh       # Package kernel + initramfs as OCI image
|   +-- extract-oci.sh            # Pure-shell rootfs extractor (dir/tar/qcow2)
|   +-- test-boot.sh              # QEMU + virtiofsd boot test helper
|   +-- test-yggdrasil-lxc.sh     # Yggdrasil LXC smoke test
|   +-- test-yggdrasil-vm.sh      # Yggdrasil virtiofs VM smoke test
|   +-- test-yggdrasil-disk.sh    # Yggdrasil qcow2 boot smoke test
|   +-- yggdrasil-smoke-test.sh   # Portable VM boot smoke test (ships with releases)
|   +-- ci-structural-tests.sh    # CI Tier 1: file/structure checks on build/ artifacts
|   +-- ci-systemd-test.sh        # CI Tier 2: rootless podman + systemd-in-OCI health (yggdrasil)
|   +-- ci-bifrost-test.sh        # CI Tier 2: bifrost ssh.service contract
|   +-- ci-canopy-test.sh         # CI Tier 2: canopy no-pid1 structural runtime
|   +-- ci-vm-boot-test.sh        # CI Tier 3: full VM boot regimen (KVM-capable host)
|   +-- create-test-rootfs.sh     # Creates minimal Debian rootfs for boot testing
|   +-- git-upstream.sh           # Manage upstream kata subtree imports
+-- docs/
|   +-- user-guide.md             # Usage documentation
|   +-- releases.md               # Release artifact inventory + CI process
|   +-- kernel-as-oci.md          # kernel-as-OCI artifact reference
|   +-- yggdrasil.md              # Yggdrasil artifact reference
|   +-- bifrost.md                # Bifrost artifact reference (SSH-ready companion)
|   +-- canopy.md                 # Canopy artifact reference (no-init companion)
|   +-- pve-integration-spec.md   # PVE config requirements for kento
+-- .github/workflows/
|   +-- release.yml               # Tag-triggered build/test/publish pipeline
+-- upstream/
|   +-- kernel/              # Kata kernel configs, patches, build script
|   +-- osbuilder/           # Kata rootfs/initrd/image builders
+-- VERSION                  # Version string
+-- LICENSE.md               # GPLv3
+-- build/                   # Output: vmlinuz + initramfs + yggdrasil artifacts (gitignored)
```

## Releases

Tagged releases (`v*`) are built automatically by
`.github/workflows/release.yml`. Each release publishes:

- **GitHub Release attachments** at
  `github.com/doctorjei/gemet/releases` — `vmlinuz`,
  `gemet-initramfs.img`, `{yggdrasil,bifrost,canopy}-<ver>.{txz,qcow2}`
  (rootfs tarballs are xz-compressed with the canonical `.txz`
  extension; build scripts emit `.txz` locally too), and plain-tar
  OCI archives (`-oci.tar`) for all three rootfs images plus
  `gemet-boot-<ver>-oci.tar` for the kernel (layer blobs are already
  gzip-compressed, so the archive isn't re-compressed).
- **OCI images on GHCR** —
  `ghcr.io/doctorjei/gemet/{yggdrasil,bifrost,canopy,boot}:<ver>`
  (all also tagged `:latest`). The kernel image publishes as `boot`;
  versions ≤ 1.5.0 were published under the old Tenkei namespace at
  `ghcr.io/doctorjei/tenkei/{yggdrasil,bifrost,canopy,tenkei-kernel}`
  and remain pullable at their original tags.

Consumers can `podman pull` the GHCR images or download the tarball/qcow2
forms directly from the release page. See
[docs/releases.md](docs/releases.md) for the full artifact inventory,
the draft-on-kernel-change gate, and how to trigger a manual pipeline
run via `workflow_dispatch`.

## Upstream Sync

Kata code is imported as git subtrees under `upstream/`. To pull latest:

```bash
bash scripts/git-upstream.sh pull
```

See `bash scripts/git-upstream.sh --help` for all commands.

## Related Projects

- [kento](https://github.com/doctorjei/kento) -- parent project. OCI images as LXC containers and VMs; owns Gemet VM lifecycle management.
- [droste](https://github.com/doctorjei/droste) -- sibling kento subproject. Nested-virtualization VM images for infrastructure testing, built on Gemet's Canopy base.
- [Kata Containers](https://github.com/kata-containers/kata-containers) -- secure container runtime using lightweight VMs; upstream source for Gemet's kernel configs.

## License

Gemet's own code is licensed under the GNU General Public License v3.0.
See [LICENSE.md](LICENSE.md) for the full text.

Upstream code in `upstream/` is from Kata Containers, licensed under Apache 2.0.
