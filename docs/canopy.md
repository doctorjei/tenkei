# Canopy

Canopy is Gemet's no-init companion image, built directly on top of
Yggdrasil. Where Yggdrasil is a full systemd foundation (pid1, udev and
dbus daemons, init meta-packages wired up) and Bifrost adds an
opinionated SSH layer on top, Canopy goes the other direction: it
**removes** the init-family from Yggdrasil, leaving a userland suitable
for no-init process containers that bring their own pid1 (tini,
dumb-init, s6-overlay) or run as bare processes.

Canopy is a derived image: `rootfs/build-canopy.sh` extracts an
existing `yggdrasil-<ver>.txz`, purges the init-family inside a
chroot, cleans residual conffiles and unit directories, and re-packages
as .txz / qcow2 / OCI. Same derivation pattern as Bifrost, inverted
intent.

## What it is

Everything Yggdrasil ships, **minus** the init-family. Canopy inherits
Yggdrasil's busybox userland, apt, dpkg, bash, the shim manifests under
`/usr/share/yggdrasil/`, and the systemd-networkd config (dead weight
without pid1, but harmless).

Removed outright:

- `systemd`, `systemd-sysv` — pid1 and SysV-init compatibility wrapper
- `systemd-resolved` — DNS resolver daemon (nothing to run under without pid1)
- `udev` — device-event daemon
- `dbus`, `dbus-bin`, `dbus-daemon`, `dbus-system-bus-common`,
  `dbus-session-bus-common` — dbus daemon + bus config
- `libkmod2`, `libnss-myhostname` — systemd-adjacent libs
- `init`, `init-system-helpers`, `sysvinit-utils`, `runit-helper` —
  init meta-packages and helpers
- `libpam-systemd`, `libdbus-1-3` — PAM and dbus client libraries
- `initramfs-tools-bin`, `klibc-utils`, `libklibc` — initramfs tooling
  (Canopy is an OCI base; it has no boot path)

Removed as cascade drags (apt autoremoved or explicitly listed for
determinism):

- `sudo` (needs `SUDO_FORCE_REMOVE=yes` during purge)
- `openssh-client`, `openssh-server`, `openssh-sftp-server`
- `procps`, `ucf`, `uuid-runtime`
- `tcpdump`, `libpcap0.8t64` (pulled along with `libdbus-1-3`)

All of these are absent from typical slim OCI base images. The
downstream `droste-seed` consumer does not need any of them.

The concrete per-build list of purged packages ships inside the image
at `/usr/share/canopy/canopy-stripped.list`.

**Retained — AppArmor parser** (pulled forward from the eventual
derive-chain inversion): Canopy keeps the `apparmor` package (and its
`apparmor_parser` binary, plus `libapparmor1`), in line with yggdrasil
and bifrost. This lets an LXC-host consumer's
`lxc.apparmor.profile = generated` (PVE's default) work without bringing
its own parser. Canopy has no pid1 and `rm -rf`s `/etc/systemd`, so
`apparmor.service` is irrelevant here and the bundled `/etc/apparmor.d`
profiles ship inert.

## The shared-library floor

Canopy is **"no pid1, no udev daemon, no dbus daemon"** — not "no
systemd at all." The following shared libraries survive the purge and
stay installed:

- `libsystemd0` — linked by many utilities and by apt itself
- `libsystemd-shared` — internal systemd helper library
- `libudev1` — linked by `util-linux`
- `libpam0g`, `libpam-modules`, `libpam-modules-bin`, `libpam-runtime`
  — hard dependencies of `util-linux` and `apt`

Removing these libraries would break package management. Apt and
util-linux hard-depend on them; there is no supported configuration of
Debian 13 where they can be purged while apt still functions. This is a
hard floor that the Canopy spike established.

Why this is fine: the libraries are inert without their corresponding
daemons running. `libsystemd0` in the absence of a running systemd is
just a linker stub that never gets called into meaningfully; `libudev1`
without `udevd` is likewise dormant. What matters for "no-init
container" semantics is the absence of the daemons and init
meta-packages — exactly what Canopy removes.

If you need to audit what's installed in a given Canopy image:

```bash
podman run --rm canopy:<ver> dpkg -l | grep '^ii' | wc -l
```

(Expect 182 ± 2 packages at v1.4.0.)

## Provenance manifest

Canopy preserves Yggdrasil's build-time manifests under
`/usr/share/yggdrasil/` (`purged-packages.list`,
`busybox-shim.manifest`, `wiped-dirs.list`) so downstream introspection
of the Yggdrasil shrink still works. Canopy adds one file of its own:

- `/usr/share/canopy/canopy-stripped.list` — sorted, unique list of the
  packages Canopy's build actually purged (direct strips plus cascade
  drags that were present at purge time)

The list is generated inside the chroot from the set of candidate
packages filtered down to only those present at purge start, so it
reflects the real purge rather than an aspirational input list.

## Residual-cleanup note

After the apt purge completes, the build script wipes a handful of
residual directories that dpkg leaves behind:

```
/etc/systemd/              — conffile residuals from purged systemd
/etc/init.d/               — SysV scripts from purged ssh/dbus
/etc/rc?.d/                — 22 rc*.d symlinks from purged pkgs
/usr/lib/systemd/          — unit files (see caveat below)
/var/lib/systemd/          — deb-systemd-helper state; stale
                             .dsh-also files would otherwise mislead
                             downstream reinstalls into skipping enable
/sbin/init                 — dangling symlink if present
/etc/resolv.conf           — symlink inherited from Yggdrasil;
                             target never materializes without pid1
```

Canopy ships **without** `/etc/resolv.conf`. The inherited Yggdrasil
symlink points at `systemd-resolved`'s runtime stub, which never
materializes in a no-init container. Consumers that add a pid1 (or
need DNS directly) are responsible for providing their own
`/etc/resolv.conf`.

The `/usr/lib/systemd/` wipe is slightly irreversible: a few unit files
there are owned by packages that **stay** installed (`apt`,
`e2fsprogs`, `util-linux`, `man-db`). Removing those files without
`dpkg-divert` leaves dpkg's file-ownership database inconsistent for
those entries.

This is an accepted trade-off — the units would never run in a no-init
context anyway, and leaving 64 KiB of dead unit files around provides
no benefit. The downstream consequence is:

- `yggdrasil-rehydrate` run on a Canopy rootfs is **not** expected to
  cleanly restore those unit files. Rehydrate is meant for Yggdrasil,
  not for Canopy. If you need a re-inited image, rebuild from
  Yggdrasil rather than rehydrating a Canopy.

## Downstream consumption

Canopy is designed for two patterns. Neither supplies a pid1 — that's
the whole point.

### Pattern 1: Bring-your-own-pid1

Drop in a minimal init shim like `tini`, `dumb-init`, or `s6-overlay`
if you want proper zombie reaping and signal forwarding:

```dockerfile
FROM canopy:1.4.0
RUN apt-get update && apt-get install -y tini && apt-get clean
COPY myapp /usr/local/bin/myapp
CMD ["tini", "--", "/usr/local/bin/myapp"]
```

### Pattern 2: Bare process runner

If you know you don't need pid1 semantics (short-lived one-shot jobs,
processes that don't spawn children, orchestrators that handle zombies
externally), run your app directly as pid1:

```dockerfile
FROM canopy:1.4.0
COPY myapp /usr/local/bin/myapp
CMD ["/usr/local/bin/myapp"]
```

Be aware that your process will receive signals directly and will be
responsible for reaping any children it spawns. Pattern 1 is the safer
default.

### `droste-seed` — the motivating consumer

The droste project's seed image was Canopy's original motivation.
Before Canopy existed, `droste-seed` was produced by a dedicated
`build-seed.sh` script that post-processed a Yggdrasil rootfs. With
Canopy as a first-party base, `droste-seed` collapses to a pure
Containerfile — no build script:

```dockerfile
FROM canopy:1.4.0
RUN useradd -m -s /bin/bash droste
COPY sysctl-droste.conf /etc/sysctl.d/99-droste.conf
CMD ["/bin/bash"]
```

This is the intended shape for droste downstream consumption: `FROM
canopy + droste user + sysctl config`, nothing more.

## Rehydrating GNU tools

Canopy inherits Yggdrasil's busybox-shim machinery: `/usr/bin/ln`,
`/usr/bin/cp`, `/usr/bin/grep`, and ~110 other canonical tool paths
are symlinks to `/usr/bin/busybox`, with `dpkg-divert` rules
redirecting each package's real binary to a `.distrib` suffix. This
works fine for most Canopy use cases, but `apt install <anything>`
downstream hits a subtle trap.

### Why `apt install coreutils` looks correct but isn't

When you `apt install coreutils` on top of Canopy, GNU `ln` lands at
`/usr/bin/ln.distrib`, not `/usr/bin/ln` — the busybox symlink keeps
owning the canonical path. dpkg reports `Setting up coreutils ... ok`,
but the next package's postinst dies on `invalid option -- 'r'` when
it calls `ln -rsf`, `cp -Z`, `chmod --reference`, `mv -Z`, or
`grep --count`. The error surfaces in the wrong package and the cause
is invisible from package-list inspection.

The full set of diversion points is enumerated in
`/usr/share/yggdrasil/busybox-shim.manifest` (inherited from
Yggdrasil; 110 entries as of canopy:1.4.0).

### Removing diversions to land real binaries at canonical paths

Strip the manifest-listed diversions, then install the GNU tools. Both
must happen in their own RUN layer **before** any other package
install — dpkg ordering inside a single transaction does not
guarantee coreutils configures first.

```dockerfile
FROM ghcr.io/doctorjei/gemet/canopy:1.5.1

# 1. Strip every busybox-shadow diversion. Leaves non-busybox diversions
#    (e.g., .usr-is-merged compat) untouched.
RUN awk '{print $2}' /usr/share/yggdrasil/busybox-shim.manifest \
    | xargs -rn1 dpkg-divert --no-rename --remove

# 2. Install the GNU replacements before any other apt transaction.
#    Order matters: anything whose postinst calls GNU long-options on
#    these tools must run after this layer, not in the same
#    transaction.
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
       coreutils grep sed findutils gzip \
    && rm -rf /var/lib/apt/lists/*

# 3. Now install whatever else you need. Postinsts will see real GNU
#    tools.
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
       <your packages here> \
    && rm -rf /var/lib/apt/lists/*
```

`--no-rename` on `dpkg-divert --remove` suppresses warnings about the
future default flip and avoids touching files — the symlinks at
canonical paths are what matter, not the `.distrib` files themselves,
which become unreferenced once the diversion is gone.

### Which tools to rehydrate

Minimum for most postinsts: `coreutils`. Add `grep`, `sed`,
`findutils`, `gzip` if any installed package's maintainer scripts use
GNU long-options on those — empirically common in Debian. The
droste reference consumer installs all five preemptively as a safety
net; cost is about 20 MB total.

Snippet contributed by the droste project as a reference consumer.

## Build

```bash
bash rootfs/build-canopy.sh              # build everything (reads VERSION)
bash rootfs/build-canopy.sh 1.4.0        # build for an explicit version
bash rootfs/build-canopy.sh --no-qcow2   # skip disk image
bash rootfs/build-canopy.sh --no-import  # skip OCI import
bash rootfs/build-canopy.sh --no-txz     # skip tarball
```

**Prerequisite:** `build/yggdrasil-<version>.txz` must already exist
(produced by `bash rootfs/build-yggdrasil.sh`). Canopy is a derived
image — it extracts the Yggdrasil tarball as its base, purges the
init-family, and re-packages. If the tarball is missing the build
script hard-fails with a pointer back to this prerequisite.

The same flag family as `build-yggdrasil.sh` and `build-bifrost.sh`:
`--no-import`, `--no-txz`, `--no-qcow2`. Any combination is valid.

Build time: about 30 s on a warm apt cache (same order as Bifrost —
it's a chroot purge, not a fresh debootstrap).

### Artifact forms

`build-canopy.sh` produces up to three artifacts:

- `build/canopy-<ver>.txz` — rootfs tarball (xz-compressed)
- `build/canopy-<ver>.qcow2` — partition-less ext4 disk image (same
  layout as Yggdrasil's qcow2; note that without a pid1 the qcow2 will
  not complete a normal boot — it is primarily useful for offline
  inspection and for testing initramfs paths that do not require init)
- `build/canopy-<ver>-oci.tar` — OCI archive (imported as
  `canopy:<ver>` and then `podman save --format=oci-archive`)

In container build environments with restricted newuidmap, rootless
podman import fails; the build script treats that as a warning and
continues with .txz + qcow2. Published releases run in CI where
rootless podman works.

## Artifact sizes (at v1.4.0)

| Image     | .txz    | qcow2   | Packages |
|-----------|---------|---------|----------|
| Yggdrasil | 56 MB   | 87 MB   | 211      |
| Canopy    | 46 MB   | 71 MB   | 182      |
| Delta     | -10 MB  | -16 MB  | -29      |

About 10 MB saved under xz compression; 29 packages removed. The
shrink is modest because Yggdrasil is already lean, and because the
shared-library floor (libsystemd0 et al.) can't be touched. The point
of Canopy is shape, not size.

## Downstream consumption summary

- **No-init process containers, bring-your-own-pid1:** use `canopy:<ver>`
  directly.
- **`droste-seed`:** `FROM canopy:<ver>` — see the droste project.
- **SSH-ready, human/ad-hoc testing:** not Canopy — use Bifrost.
- **Full systemd + networkd, droste tiers / kento fixtures:** not
  Canopy — use Yggdrasil.

---

*Last updated: 2026-04-24 (Gemet 1.5.1 — namespace switch; `.dsh-also` leak closed via `/var/lib/systemd` wipe in post-purge cleanup)*
