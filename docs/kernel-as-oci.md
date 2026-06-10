# Kernel as OCI

The kernel image is a single-layer OCI image containing Gemet's
prebuilt kernel and initramfs. Published to GHCR as
`ghcr.io/doctorjei/gemet/boot:<version>`; built locally as
`localhost/gemet-kernel:<version>`. It is a companion artifact to the
raw files produced under `build/` — additive, not a replacement.

## What it is

A `FROM scratch` image with exactly two files:

```
/boot/vmlinuz
/boot/initramfs.img
```

Nothing else — no shell, no libc, no metadata beyond what `FROM scratch`
implies. The image is only useful as a source in a multi-stage build; you
cannot run it, exec into it, or use it as a rootfs.

Purpose: let downstream consumers pull Gemet's kernel and initramfs via
`COPY --from=<boot-image>` rather than having Gemet's source tree or
build output staged on disk next to their Containerfile.

## Pulling from GHCR

As of Gemet 1.5.1, tagged releases are published to
`ghcr.io/doctorjei/gemet/boot:<ver>` (and `:latest`):

```bash
podman pull ghcr.io/doctorjei/gemet/boot:1.5.1
```

Versions 1.0.0 – 1.5.0 were published to
`ghcr.io/doctorjei/tenkei/tenkei-kernel:<ver>` and remain pullable at
their original tags. The local build tag was also
`localhost/tenkei-kernel:<ver>` in ≤ 1.5.0 and renamed to
`localhost/gemet-kernel:<ver>` in 1.5.1. Image internals (scripts,
labels, paths inside the rootfs) still carry the `tenkei` name —
the full internal rename lands with the v2.0.0 Gemet migration.

See [releases.md](releases.md) for the full artifact inventory and the
draft-gate process for kernel/initramfs-touching releases.

## Build

First produce the raw build outputs, then package them:

```bash
bash scripts/build-kernel.sh <kver>       # populates build/vmlinuz + build/gemet-initramfs.img
bash scripts/build-kernel-oci.sh          # uses ./VERSION
# or
bash scripts/build-kernel-oci.sh 1.5.1    # explicit version
```

Output: OCI image tagged `localhost/gemet-kernel:<version>` and
`localhost/gemet-kernel:latest`.

## Image contents

The Containerfile is deliberately trivial:

```dockerfile
FROM scratch

COPY vmlinuz /boot/vmlinuz
COPY initramfs.img /boot/initramfs.img
```

Two files, one layer, no runtime behavior.

## Downstream usage

The intended consumption pattern is a multi-stage Containerfile:

```dockerfile
FROM ghcr.io/doctorjei/gemet/boot:1.5.1 AS kernel

FROM debian:bookworm  # or yggdrasil:<ver>, etc.
COPY --from=kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=kernel /boot/initramfs.img /boot/initramfs.img

# ... rest of the VM-bootable image setup (empty fstab, password,
# systemd-networkd DHCP, udev, systemd-sysv) ...
```

This replaces the older pattern of staging `vmlinuz` + `initramfs.img`
next to the Containerfile and using direct `COPY` statements.

For consumers building locally against an unpublished version,
`localhost/gemet-kernel:<ver>` works the same way as the GHCR tag.

## Version compatibility

The boot image uses Gemet's own `VERSION` as its tag. The kernel
and initramfs inside are whatever was in `build/` at the time the image
was packaged, so Gemet's version reflects the project release, not the
Linux kernel version.

Downstream consumers that need a specific kernel version should pin on
Gemet's `VERSION` — this pins the kernel version that Gemet's build
scripts are wired up against for that release.

## Relationship to Kata kernels

Gemet's kernel is built from upstream Kata's tree (configs + patches)
plus a thin gemet-side config overlay. `scripts/build-kernel.sh` runs
Kata's `setup` step to merge Kata's fragments, then layers
`kernel/config/<arch>/gemet.conf` on top via `merge_config.sh -m` and a
final `make olddefconfig` before the build proceeds.

The overlay now sets several gemet-specific options, grouped by purpose:

```
# ACPI power-button delivery (PVE qm shutdown over QMP)
CONFIG_INPUT_EVDEV=y

# KVM host: nested-virt /dev/kvm for droste's PVE-node tier
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
CONFIG_KVM_INTEL=y
CONFIG_KVM_AMD=y

# Block drivers for droste's HA/storage tiers (CONNECTOR is a DRBD dep)
CONFIG_CONNECTOR=y
CONFIG_BLK_DEV_NBD=y
CONFIG_BLK_DEV_DRBD=y

# LSM: AppArmor is the active MAC; SELinux stays compiled but dormant
CONFIG_AUDIT=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor"

# PSI active at boot so /proc/pressure exists (PVE pressure reporting / qm status)
CONFIG_PSI_DEFAULT_DISABLED=n
```

`CONFIG_INPUT_EVDEV` exists because Kata's target use case (kata-agent
over vsock) doesn't need userspace ACPI event delivery, so their fragments
leave it unset. Gemet's consumers (e.g. PVE `qm shutdown`, which sends an
ACPI power-button press over QMP) need `/dev/input/event*` to exist so
`systemd-logind` can react — without it ACPI events are dropped and the
host falls back to forceStop after a timeout.

The KVM host group gives gemet the hypervisor-side drivers that create
`/dev/kvm`. Kata ships `CONFIG_KVM_GUEST=y` (paravirt-as-guest) but omits
the host half; droste boots this kernel as a nested-virt PVE node, which
needs both.

The block group covers `nbd`/`drbd`, which droste autoloads via
`modules-load.d` for its HA/storage tiers; Kata's allnoconfig base omitted
them. `CONFIG_CONNECTOR` is the explicit DRBD dependency.

The LSM group makes AppArmor the active major MAC. Kata compiles SELinux
in with no explicit `CONFIG_LSM`, so the kernel default put SELinux ahead
of AppArmor; with no policy shipped it errored on every boot while AppArmor
never initialized. Setting `CONFIG_LSM` with apparmor as the only major
makes AppArmor active and keeps SELinux dormant-but-re-enablable at boot.

`CONFIG_PSI_DEFAULT_DISABLED=n` makes pressure stall information active at
boot. Kata compiles PSI in (`CONFIG_PSI=y`) but leaves it runtime-disabled,
so `/proc/pressure/` is absent unless the cmdline carries `psi=1`; PVE's
`qm status` then reads undef for the per-VM pressure fields and emits
"uninitialized value" Perl warnings. Flipping the default off restores
`/proc/pressure/` without a `psi=1` cmdline.

AppArmor is active in the kernel, and yggdrasil and bifrost ship the
`apparmor_parser` binary (the `apparmor` package is retained) while **masking
`apparmor.service`** so the package's ~90 bundled `/etc/apparmor.d` profiles are
not loaded at boot. The result is still inert: AppArmor is active but no profile
is applied until a consumer parses one on demand. Keeping the parser without
auto-enforcing the bundled set keeps the base minimal in behavior while making
the tool available where a runtime needs it. Canopy retains the parser too
(pulled forward from the eventual derive-chain inversion): as a no-init OCI
payload it has no `apparmor.service` to mask, but keeping the `apparmor` package
lets an LXC-host consumer's `lxc.apparmor.profile = generated` work without
bringing its own parser.

This matters for hosts that run containers. A container runtime that applies an
AppArmor profile needs the userspace parser (`apparmor_parser`). LXC with
`lxc.apparmor.profile = generated` (PVE's default) shells out to the parser at
container start, independent of `apparmor.service`. Because yggdrasil, bifrost,
and canopy ship the parser, `generated` now works out of the box on such a host
— no hard-fail. The underlying issue is still an LXC-side gap: the `apparmor` package
is only a `Recommends` of `lxc`, yet the `generated` path hard-requires it. A
parser-less host therefore still aborts at LSM init with `Cannot use generated
profile: apparmor_parser not available` (it does not fall back to unconfined) —
e.g. after `apt-get install --no-install-recommends lxc` on a host that lacks
the parser. The fixes there are downstream: install `lxc` with recommends enabled
(which pulls `apparmor`), or set `lxc.apparmor.profile = unconfined`. gemet
shipping the parser across yggdrasil, bifrost, and canopy is a courtesy that
removes the footgun for the common case, not an obligation of the base.

Every overlay *driver* is builtin (`=y`), never a module: gemet ships only
`vmlinuz` + initramfs (`kernel/Containerfile` is `FROM scratch` + COPY of
the two boot files; the build has no `make modules_install` and no
`/lib/modules` tree). A `=m` driver would compile but never reach a
consumer. (`CONFIG_PSI_DEFAULT_DISABLED=n` is a tuning default, not a
driver — it has no module form.) `scripts/build-kernel.sh` asserts every
overlay `CONFIG_*=` line survived `make olddefconfig` and fails the build
if any was dropped — including, for a disabled bool, the comment form
(`# CONFIG_X is not set`) that `olddefconfig` writes instead of `=n`.

Practical consequence: gemet's `vmlinuz` is binary-compatible with the
boot interface Kata exposes (same kernel version, same Kata configs and
patches as the foundation), but the resulting `.config` differs by the
overlay above. A Kata-published kernel binary is not a drop-in
substitute — it lacks the gemet overlay's options and would reintroduce
the bugs the overlay fixes. Always build via `scripts/build-kernel.sh`
(or pull from `ghcr.io/doctorjei/gemet/boot:<ver>`).

The overlay is intentionally minimal — only what Kata doesn't provide
that gemet specifically needs. Bumping the kernel version is the same
operation as building one for the first time; the overlay is reapplied
automatically by the build script.

## Why OCI

The raw files (`build/vmlinuz` and `build/gemet-initramfs.img`) still
exist and remain the primary artifact. The OCI form is additive — for
consumers that want a referenceable artifact URL rather than out-of-band
file copies. Nothing that uses the raw files has to change.

## Relationship to Yggdrasil

[Yggdrasil](yggdrasil.md) and kernel-as-OCI are independent artifacts
that compose naturally: Yggdrasil gives you a minimal Debian userland;
kernel-as-OCI gives you the boot stack. A "full VM image" Containerfile
typically pulls from both:

```dockerfile
FROM ghcr.io/doctorjei/gemet/boot:1.5.1 AS kernel

FROM ghcr.io/doctorjei/gemet/yggdrasil:1.5.1
COPY --from=kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=kernel /boot/initramfs.img /boot/initramfs.img

# ... your customizations ...
```

---

*Last updated: 2026-04-24 (Gemet 1.5.1 — namespace switch + kernel package rename to `boot`)*
