# Yggdrasil

Yggdrasil is Gemet's minimal Debian 13 + systemd foundation image. It serves
as the base layer for downstream rootfs builds (droste tiers, kento test
fixtures, user-defined images) and is published in three artifact forms: OCI
image, `.txz` tarball (xz-compressed), and qcow2 disk image.

As of 1.2.0, the build applies a multi-phase shrink pass (BusyBox swap,
targeted purges, doc/locale/man sweep, python library trim) that reduces
the rootfs from ~377 MB to ~210-230 MB (~40% reduction). Recovery tooling
ships in the image so downstream consumers can reverse individual
shadows or fully rehydrate when needed.

## What it is

A stripped-down Debian 13 genericcloud rootfs with:

- systemd as PID 1 (udev, dbus kept; polkitd and timesyncd dropped)
- systemd-networkd configured for DHCP on all ethernet interfaces
- systemd-resolved enabled; `/etc/resolv.conf` → `/run/systemd/resolve/stub-resolv.conf`
- openssh-server installed but **disabled by default** (no host keys
  ship — see "SSH host keys" below)
- busybox providing shim coverage for 18 swapped-out packages
  (hostname, gzip, sed, grep, findutils, iproute2, etc.)
- nano, vim-tiny, curl, tcpdump, iptables kept for "poke around" ergonomics
- bash kept as `/bin/sh` (via dpkg-divert) — busybox's ash is not the
  default shell
- Locales for 15 common regions compiled into `/usr/lib/locale/locale-archive`
  (the `locales` package itself is purged after generation)

Kernel and bootloader packages are purged: Yggdrasil boots via an external
kernel + initramfs (Gemet's own — see [kernel-as-oci](kernel-as-oci.md))
rather than a self-contained boot stack.

## Shrink phases

`rootfs/build-yggdrasil.sh` runs five strip phases (plus the initial
debootstrap). Phase 0 is the historical 1.1.0 pass; phases 1-4 were
added in 1.2.0. Build-time manifests for every shim and purge land in
`/usr/share/yggdrasil/` so downstream can introspect or reverse the
changes — see [Recovery tooling](#recovery-tooling) below.

| Phase | Scope                            | Approx saving |
|-------|----------------------------------|---------------|
| 0     | Kernel/boot + Yggdrasil purges   | (baseline)    |
| 1     | BusyBox swap (18 packages)       | ~36 MB        |
| 2     | Targeted purges + locales trim   | ~30 MB        |
| 3     | Doc/info/man/locale sweep        | ~71 MB        |
| 4     | Python library trim (31 pkgs)    | ~13 MB        |
| —     | **Total (phases 1-4)**           | **~150 MB**   |

### Phase 0 — Kernel/boot + Yggdrasil strip (baseline, unchanged from 1.1.0)

Purges the kernel/bootloader chain and the Yggdrasil-specific package
list, then `apt autoremove --purge` to reclaim orphaned deps. Also wipes
`/boot/*` and `/lib/modules/*` and replaces `/etc/fstab` with an empty
placeholder (stale UUID mounts from genericcloud hang boot in
VM/container contexts). Passing `--no-shrink` to the build script stops
here and produces a 1.1.0-equivalent image.

### Phase 1 — BusyBox swap

Installs `busybox` and purges 18 packages whose utilities BusyBox
covers: `hostname`, `iputils-ping`, `gzip`, `cpio`, `sed`, `coreutils`,
`grep`, `findutils`, `diffutils`, `less`, `wget`, `kmod`,
`netcat-openbsd`, `traceroute`, `fdisk`, `psmisc`, `iproute2`, `dash`.
`/bin/sh` is repointed at `bash` via `dpkg-divert` before `dash` is
purged (BusyBox's `ash` is intentionally not the default shell).

Shim installation uses `busybox --install -s` into a scratch directory,
then mirrors the resulting symlinks into the live FS only where the
target path is empty. This exists-check naturally gates shims against
packages that are kept — `systemd-sysv`, `util-linux`, `procps`,
`shadow`, `vim-tiny`, `bash` all retain their own binaries.

### Phase 2 — Targeted purges and locale compaction

Purges `libc-l10n`, `file`, `libmagic1t64`, and `libmagic-mgc`. Then
runs `locale-gen` to compile the 15-region locale archive at
`/usr/lib/locale/locale-archive`, and **after** that purges the
`locales` package itself. The compiled archive survives because it is
not package-owned — apps calling `setlocale` still find their locale
data.

### Phase 3 — Doc/info/man/locale sweep

Wipes `/usr/share/doc` and `/usr/share/info` entirely. Trims
`/usr/share/man` down to the English man sections, and trims
`/usr/share/locale` to the 15 locale-gen'd families (`en`, `zh`, `hi`,
`es`, `ar`, `fr`, `bn`, `pt`, `id`, `ur`, `de`, `ja`, `ko`, plus
region variants). `apt` cache and `/var/lib/apt/lists/*` are cleaned
last.

### Phase 4 — Python library purge

Purges 31 `python3-*` packages that have no non-Python reverse
dependencies (pulled in by cloud-init / reportbug / apt-listchanges
and left as orphans by autoremove's conservative rules). The base
interpreter stack is kept: `python3`, `python3.13`, `python3.13-minimal`,
`libpython3.13-minimal`, `libpython3.13-stdlib`.

## What's kept vs dropped

Relative to the Debian 13 genericcloud rootfs, Yggdrasil makes the
following targeted changes (see `rootfs/build-yggdrasil.sh` for the
authoritative package lists):

**Kept** (beyond the genericcloud default):

- `busybox` — core ergonomics + shim coverage for 18 swapped packages
- `bash` — retained as `/bin/sh` (dpkg-diverted before `dash` purge)
- `vim-tiny` — provides `/usr/bin/vi` after `vim`/`vim-common`/`vim-runtime`
  are dropped
- `nano` — explicit install (Debian default `$EDITOR`)
- `curl`, `tcpdump`, `iptables` — convenience tools that survive
  autoremove (`wget` and `traceroute` now come from busybox)
- Python interpreter stack (`python3`, `python3.13`,
  `python3.13-minimal`, `libpython3.13-minimal`, `libpython3.13-stdlib`)

**Dropped — kernel/boot** (Phase 0):

- `linux-image-cloud-amd64`, `linux-sysctl-defaults`
- `grub-*`, `shim-*`, `mokutil`, `os-prober`, UEFI libs
- `netplan.io` + `netplan-generator` + `python3-netplan`
- `cloud-initramfs-growroot`, `dracut-install`, `pciutils`

**Dropped — Yggdrasil-specific** (Phase 0):

- `cloud-init`, `cloud-guest-utils`, `cloud-image-utils`, `cloud-utils`
- `polkitd`, `libpolkit-agent-1-0`, `libpolkit-gobject-1-0`
- `systemd-timesyncd` (DNS is handled by `systemd-resolved`, which is
  kept and enabled; `/etc/resolv.conf` is a symlink to the resolved
  stub at `/run/systemd/resolve/stub-resolv.conf`)
- `unattended-upgrades`, `dmsetup`
- `screen`, `qemu-utils`, `dosfstools`, `gdisk`, `genisoimage`
- `dhcpcd-base` (redundant with networkd)
- `reportbug`, `python3-reportbug`, `python3-debianbts`,
  `apt-listchanges`
- `ssh-import-id` (we have our own key injection)
- `bind9-host`, `bind9-libs` (`host`/`dig` not foundational; `ping` and
  name resolution still work via libc's `getaddrinfo`)
- `vim`, `vim-common`, `vim-runtime` (replaced by `vim-tiny`)

**Retained — AppArmor parser** (v1.7.3+): the `apparmor` package (and
`apparmor_parser`) is kept, with `apparmor.service` masked so the ~90
bundled profiles do not auto-enforce. This lets LXC
`lxc.apparmor.profile = generated` (PVE's default) work on a
yggdrasil/bifrost host instead of hard-failing on a missing parser.
Canopy now retains the parser as well (pulled forward from the eventual
derive-chain inversion), so the same `generated` path works there too. See
[kernel-as-oci.md](kernel-as-oci.md) for the full rationale.

**Dropped — BusyBox swap** (Phase 1):

`hostname`, `iputils-ping`, `gzip`, `cpio`, `sed`, `coreutils`, `grep`,
`findutils`, `diffutils`, `less`, `wget`, `kmod`, `netcat-openbsd`,
`traceroute`, `fdisk`, `psmisc`, `iproute2`, `dash`. See
`/usr/share/yggdrasil/busybox-shim.manifest` for the exact
package-to-shim mapping written at build time.

**Dropped — targeted** (Phase 2):

- `libc-l10n`, `file`, `libmagic1t64`, `libmagic-mgc`
- `locales` (purged after `locale-gen` compiles the archive;
  `/usr/lib/locale/locale-archive` survives)

**Dropped — Python libraries** (Phase 4):

31 `python3-*` packages with no non-Python reverse deps. See
`/usr/share/yggdrasil/purged-packages.list` for the exact list.

If a downstream consumer needs any of the dropped packages back, see
[Recovery tooling](#recovery-tooling).

## Recovery tooling

Two scripts ship at `/usr/share/yggdrasil/` with symlinks in
`/usr/local/bin/`. They read the build-time manifests also installed
at `/usr/share/yggdrasil/`:

- `purged-packages.list` — one per line, every package purged across
  phases 1-4 (and the Phase 2 sub-purge of `locales`)
- `busybox-shim.manifest` — tab-separated `<pkg>\t<shim-path>`
- `wiped-dirs.list` — top-level dirs wiped in Phase 3
  (`/usr/share/doc`, `/usr/share/info`, `/usr/share/locale`,
  `/usr/share/man`)

### `yggdrasil-unshim`

Removes the BusyBox shim symlinks for one or more swapped packages so
the real package can be reinstalled cleanly.

```bash
yggdrasil-unshim --list                # show all shimmed packages
yggdrasil-unshim grep findutils        # remove shims for these pkgs
yggdrasil-unshim --all                 # remove every shim
apt-get install grep findutils         # reinstall real binaries
```

Use this when a downstream tier needs a specific utility's full
behavior (e.g. GNU `grep -P` perl regexes that busybox doesn't cover).

### `yggdrasil-rehydrate`

One-shot full restoration. Removes all shims, reinstalls every
package listed in `purged-packages.list`, then runs `apt-get install
--reinstall` over the entire installed package set to repopulate the
wiped `/usr/share/{doc,info,man,locale}` trees. Takes 2-5 minutes.

```bash
yggdrasil-rehydrate --dry-run          # list actions without executing
yggdrasil-rehydrate                    # perform full rehydration
```

After rehydration the image is functionally equivalent to a fresh
Debian 13 install of the same package set — useful for debugging or
for distributing a "fat" base to environments where the shrink isn't
worth the trade-off.

## Build

```bash
sudo bash rootfs/build-yggdrasil.sh           # OCI + .txz + qcow2 (default)
```

`build-yggdrasil.sh` produces all three artifacts by default:

- OCI image `yggdrasil:<version>` (version from Gemet's `VERSION` file)
- `build/yggdrasil-<version>.txz`
- `build/yggdrasil-<version>.qcow2`

The qcow2 is extracted from the built rootfs using `debugfs rdump`
(works in environments without a loadable `nbd` module, e.g. dev
containers) rather than `qemu-nbd`.

Flags to selectively skip outputs (independent, any combination):

- `--no-import` — don't import into podman as an OCI image
- `--no-txz` — don't produce the tarball
- `--no-qcow2` — don't produce the disk image
- `--no-shrink` — stop after Phase 0 (produces a 1.1.0-equivalent
  image, useful as a fallback if a shrink phase regresses something)

## Artifact forms

Yggdrasil is published in three artifact forms, all produced from the
same rootfs work directory in a single build invocation:

| Form        | Output                                    | Primary consumer                         |
|-------------|-------------------------------------------|------------------------------------------|
| OCI image   | `yggdrasil:<ver>` (in podman/docker)      | droste tiers, kento test fixtures        |
| `.txz`      | `build/yggdrasil-<ver>.txz`               | `lxc-create -t local --rootfs=<tarball>` |
| qcow2       | `build/yggdrasil-<ver>.qcow2`             | External boot via `qemu -kernel -initrd` |

Tagged releases (from 1.5.1 onward) publish the OCI image to GHCR at
`ghcr.io/doctorjei/gemet/yggdrasil:<ver>` (and `:latest`), and the
.txz + qcow2 + `-oci.tar` forms as GitHub Release attachments. Earlier
versions (≤ 1.5.0) remain at
`ghcr.io/doctorjei/tenkei/yggdrasil:<ver>`. See
[releases.md](releases.md) for pull commands and the full artifact
inventory.

### Converting an existing OCI archive

`scripts/extract-oci.sh` is a pure-shell utility (no podman/umoci/root)
that reads an OCI image archive — e.g. the output of
`podman save --format=oci-archive yggdrasil:<ver>` or any droste tier
exported the same way — and re-emits it in any of the three forms:

```bash
scripts/extract-oci.sh --dir   image.oci.tar /tmp/rootfs
scripts/extract-oci.sh --tar   image.oci.tar rootfs.tar
scripts/extract-oci.sh --qcow2 image.oci.tar rootfs.qcow2
```

The `--qcow2` mode produces the same partition-less single-ext4 layout
described in [qcow2 boot contract](#qcow2-boot-contract-disk-image-artifact)
below, and uses the unprivileged `mkfs.ext4 -d` path. Use this when you
already have an OCI tarball and want a disk image without re-running the
full Yggdrasil build.

## Boot contracts

### virtiofs boot (OCI artifact, droste tiers)

Droste tiers layer on top of `yggdrasil:<ver>` and add Gemet's kernel +
initramfs via [kernel-as-oci](kernel-as-oci.md). The resulting image is
booted by kento over virtiofs, following Gemet's default contract:

```
root=rootfs rootfstype=virtiofs
```

This is the existing kento/Gemet boot path — no change from previous
Gemet releases.

### qcow2 boot contract (disk-image artifact)

The qcow2 is a **partition-less** single ext4 filesystem — no partition
table, no bootloader, no `/boot`. That means the guest sees the rootfs at
`/dev/vda`, not `/dev/vda1`. The kernel cmdline must include:

```
root=/dev/vda rootfstype=ext4
```

Gemet's initramfs dispatches on those cmdline args and mounts the block
device directly (see `initramfs/init`). The corresponding boot invocation
is:

```bash
qemu-system-x86_64 \
    -kernel build/vmlinuz \
    -initrd build/gemet-initramfs.img \
    -drive file=build/yggdrasil-<ver>.qcow2,format=qcow2,if=virtio \
    -append "console=ttyS0 root=/dev/vda rootfstype=ext4"
```

`scripts/test-yggdrasil-disk.sh` wraps this with sensible defaults.

## SSH host keys

Yggdrasil ships **no** `/etc/ssh/ssh_host_*_key` files and **ssh.service
is disabled by default**. The Debian `genericcloud` base relies on
cloud-init to generate host keys at first boot; Yggdrasil strips
cloud-init, so that path is unavailable. Rather than shipping identical
keys in every instance or running an unconditional first-boot keygen
(either of which bakes a policy into a base image that shouldn't have
one), host-key provisioning is left to the downstream tier.

To enable SSH in a downstream image, do two things in the tier's
Containerfile (or equivalent):

1. Place host keys under `/etc/ssh/` — either generate them at build
   time (`ssh-keygen -A -f /etc/ssh`), inject pre-generated keys, or
   ship a oneshot unit that runs `ssh-keygen -A` on first boot.
2. Re-enable the service: `systemctl enable ssh.service ssh.socket`.

## Downstream consumption

Yggdrasil is designed to be the base for downstream Containerfile
layering. The canonical pattern combines Yggdrasil with Gemet's
[kernel-as-oci](kernel-as-oci.md) image to produce a self-contained
VM-bootable image in a single Containerfile:

```dockerfile
FROM ghcr.io/doctorjei/gemet/boot:1.5.1 AS kernel

FROM ghcr.io/doctorjei/gemet/yggdrasil:1.5.1
COPY --from=kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=kernel /boot/initramfs.img /boot/initramfs.img

# ... your customizations ...
```

Droste tiers will follow this pattern: each tier builds `FROM
ghcr.io/doctorjei/gemet/yggdrasil:<ver>` (or from an earlier tier built
on top of Yggdrasil) and pulls the kernel/initramfs from
`ghcr.io/doctorjei/gemet/boot:<ver>` via `COPY --from=`.

Downstream customizations are unrestricted — add packages, write config,
create users, disable services. Each downstream image owns its own user
and authorized-keys policy; Yggdrasil ships neither.

If a downstream tier needs to reinstall a BusyBox-shimmed package or
fully rehydrate the image, use `yggdrasil-unshim` or
`yggdrasil-rehydrate` (see [Recovery tooling](#recovery-tooling)) from
a `RUN` step in the tier's Containerfile.

### Downstream images in Gemet

**Bifrost** is the first-party SSH-ready companion image: Yggdrasil plus
an opinionated SSH layer (sshd enabled, host keys generated at first
boot, `/etc/bifrost/authorized_keys` sync). It's built as a derived
image from an existing `yggdrasil-<ver>.txz`. If you want an
SSH-ready base for humans or ad-hoc testing, use `bifrost:<ver>`
directly; if you need a different user model, build `FROM
yggdrasil:<ver>` and roll your own. See [bifrost.md](bifrost.md).

**Canopy** is the first-party no-init companion image — the inverse
shape from Bifrost. Where Bifrost **adds** opinion (sshd, key sync),
Canopy **removes** it: the init-family (systemd pid1, udev daemon,
dbus daemon, init meta-packages and their cascade) is purged, leaving
a base suitable for no-init process containers where the caller brings
their own pid1 (tini, dumb-init) or runs as a bare process. It's built
as a derived image from the same `yggdrasil-<ver>.txz`. The
motivating consumer is `droste-seed`. See [canopy.md](canopy.md).

## Testing

Minimum-viable boot tests for a freshly-built `yggdrasil:<ver>`:

```bash
sudo bash scripts/test-yggdrasil-lxc.sh
sudo bash scripts/test-yggdrasil-vm.sh
bash     scripts/test-yggdrasil-disk.sh
```

The LXC test boots Yggdrasil as a system container and runs a few probes
via `lxc-attach` (`systemctl is-system-running`, `/etc/os-release`,
`id root`). Pass `--keep` to leave the container in place for post-mortem.

The VM test extracts the OCI rootfs to a temp dir, ensures
`serial-getty@ttyS0.service` is enabled (genericcloud historically skips
it), and hands off to `scripts/test-boot.sh` for the virtiofsd + QEMU
heavy lifting. Extra flags after `--` are forwarded (e.g. `-- --dax`,
`-- --no-kvm`).

The disk test boots the qcow2 artifact directly via QEMU with Gemet's
kernel + initramfs — no virtiofsd. Default SSH forward is `localhost:2223`
(different from the VM test's 2222 so both can run concurrently).

---

*Last updated: 2026-04-24 (Gemet 1.5.1 — namespace switch)*
