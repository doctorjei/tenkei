# Releases

Gemet publishes releases automatically from tagged commits. Artifacts
land in two forms: **GitHub Release attachments** (raw files, for direct
download and manual consumption) and **OCI images on GHCR** (for
`podman pull` and multi-stage container builds). Gemet releases
independently from its parent project
[kento](https://github.com/doctorjei/kento); kento pulls Gemet
artifacts like any other downstream consumer.

Releases use an **rc-then-promote** flow (since v1.6.0). Push a
release-candidate tag (`v<ver>-rc<n>`) to trigger the build +
test + GHCR push (rc-suffixed only) + DRAFT release. Once the rc
is verified, push the matching plain tag (`v<ver>`) to trigger
the promote job: skopeo-copy rc images to `:<ver>` + `:latest`,
flip the rc draft to published. See "How to trigger a release"
below.

## Artifact inventory (per release)

### GitHub Release attachments

Attached to the release page at `github.com/doctorjei/gemet/releases/tag/v<ver>`:

| File                               | Size     | Purpose                                                              |
|------------------------------------|---------:|----------------------------------------------------------------------|
| `vmlinuz`                          | ~7.5 MB  | Compressed kernel. Drop at `build/vmlinuz` to skip local compile.    |
| `gemet-initramfs.img`              | ~1.1 MB  | gzip+cpio initramfs (busybox + virtiofs-aware init script).          |
| `yggdrasil-<ver>.txz`              |  ~57 MB  | Yggdrasil rootfs tarball (xz-compressed).                            |
| `yggdrasil-<ver>.qcow2`            |  ~87 MB  | Bootable partition-less ext4 disk image for `qemu -drive`.           |
| `yggdrasil-<ver>-oci.txz`          |  ~60 MB  | OCI archive of the Yggdrasil image (air-gapped `podman load`, xz-compressed). |
| `bifrost-<ver>.txz`                |  ~57 MB  | Bifrost (SSH-ready) rootfs tarball.                                  |
| `bifrost-<ver>.qcow2`              |  ~87 MB  | Bootable Bifrost disk image.                                         |
| `bifrost-<ver>-oci.txz`            |  ~60 MB  | OCI archive of the Bifrost image (xz-compressed).                    |
| `canopy-<ver>.txz`                 |  ~46 MB  | Canopy (no-init) rootfs tarball. Not independently bootable.         |
| `canopy-<ver>.qcow2`               |  ~71 MB  | Canopy disk image (composition base — no pid1).                      |
| `canopy-<ver>-oci.txz`             |  ~49 MB  | OCI archive of the Canopy image (xz-compressed).                     |
| `gemet-boot-<ver>-oci.txz`         |  ~7 MB   | OCI archive of the kernel-only image (multi-stage `COPY --from=`, xz-compressed). |

Rootfs archives are published as `.txz` (same xz format, canonical
shorter extension — `.tar.xz` through v1.4.1, renamed on the release
page at v1.4.2, and renamed at the build-script layer thereafter).
OCI-archive release attachments are xz-compressed on the release page
as `-oci.txz` — GHCR push format (uncompressed OCI, served by the
registry) is unchanged. `podman load` accepts the xz-compressed form
natively.

### OCI images on GHCR

As of 1.5.1, images push to `ghcr.io/doctorjei/gemet/` at both the
exact version and `:latest`:

| Image                                                | What it contains                                               |
|------------------------------------------------------|----------------------------------------------------------------|
| `ghcr.io/doctorjei/gemet/yggdrasil:<ver>`            | Yggdrasil rootfs (Debian + systemd). See [yggdrasil.md](yggdrasil.md). |
| `ghcr.io/doctorjei/gemet/bifrost:<ver>`              | Yggdrasil + SSH opinion layer. See [bifrost.md](bifrost.md).   |
| `ghcr.io/doctorjei/gemet/canopy:<ver>`               | Yggdrasil minus init-family (no pid1). See [canopy.md](canopy.md). |
| `ghcr.io/doctorjei/gemet/boot:<ver>`                 | `/boot/vmlinuz` + `/boot/initramfs.img`. See [kernel-as-oci.md](kernel-as-oci.md). |
| `...:latest`                                         | Alias for the most recent tagged release (all 4 images).       |

Versions 1.0.0 – 1.5.0 published to
`ghcr.io/doctorjei/tenkei/{yggdrasil,bifrost,canopy,tenkei-kernel}`
and remain pullable at their original tags. The kernel package renamed
from `tenkei-kernel` to `boot` with the namespace switch.
Release-attachment filenames also rename at 1.5.1 —
`tenkei-initramfs.img` → `gemet-initramfs.img` and
`tenkei-kernel-<ver>-oci.txz` → `gemet-boot-<ver>-oci.txz`. Image
internals (scripts, labels, variable names inside the rootfs) still
carry the `tenkei` prefix; the full internal rename lands in v2.0.0.

Pulls work anonymously for public images:

```bash
podman pull ghcr.io/doctorjei/gemet/yggdrasil:1.5.1
podman pull ghcr.io/doctorjei/gemet/bifrost:1.5.1
podman pull ghcr.io/doctorjei/gemet/canopy:1.5.1
podman pull ghcr.io/doctorjei/gemet/boot:1.5.1
```

Downstream multi-stage consumers (droste, kento test fixtures) should pull
`boot:<ver>` in a `FROM` stage and `COPY --from=` the two boot files
into their own rootfs image. See
[docs/kernel-as-oci.md](kernel-as-oci.md) for the canonical pattern.

### Kento composition pattern

Kento (Gemet's parent project — OCI-to-LXC/VM runner) expects a
**single composed image** with both rootfs and
`/boot/{vmlinuz,initramfs.img}` present. Compose the two Gemet images
with a two-line Containerfile:

```dockerfile
FROM ghcr.io/doctorjei/gemet/boot:1.5.1 AS kernel
FROM ghcr.io/doctorjei/gemet/bifrost:1.5.1
COPY --from=kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=kernel /boot/initramfs.img /boot/initramfs.img
```

Push the composed image to your own registry (or `podman save` + copy),
then hand it to `kento vm create --image ...`. Yggdrasil or Canopy work
as the rootfs base too — pick the one that matches your init needs.

## Release cadence and the draft gate

Every tag push runs the full pipeline. How the release is published
depends on what code changed since the previous tag:

- **Rootfs-only changes** (paths under `rootfs/`, `docs/`, or most of
  `scripts/`) publish immediately on green tests. No human gate.

- **Kernel or initramfs changes** (paths under `initramfs/`,
  `upstream/kernel/`, `kernel/`, `scripts/build-kernel*.sh`, or the
  workflow file itself) publish as **drafts** with a pre-publish
  checklist in the release body. The release is flagged `Draft` in the
  GitHub UI and its artifacts are only visible to maintainers.

A draft release is the CI's signal that the change surface includes
things the Tier 1+2 checks cannot fully validate (kernel boot,
initramfs `switch_root`, virtiofs handoff). A maintainer runs
`scripts/yggdrasil-smoke-test.sh` against the draft's artifacts on a
KVM-capable host, confirms all 5 serial-console checkpoints pass, then
flips the draft via the UI or:

```bash
gh release edit v<ver> --draft=false
```

Future work — see `~/playbook/tasks.md` "Gold tier" — will automate this
step via a self-hosted or KVM-enabled runner.

## How to trigger a release

Gemet uses an **rc-then-promote** pattern (since v1.6.0). Two tags
per release:

```bash
# 1. Tag a release candidate. Builds, runs Tier 1/2, pushes
#    GHCR with rc suffix only (`:<ver>-rc1`), creates DRAFT release.
git tag -a v1.6.3-rc1 -m "Release candidate v1.6.3-rc1"
git push origin v1.6.3-rc1

# 2. After verifying the rc on a test host, tag the release. NO
#    rebuild — the workflow skopeo-copies the rc images to
#    `:<ver>` and `:latest`, then flips the rc draft to published.
git tag -a v1.6.3 -m "Release v1.6.3"
git push origin v1.6.3
```

The rc tag is mutable (force-pushable) under the `v*-rc*` exclusion
in the tag protection rule, so a broken rc can be fixed and re-
pushed without bumping the rc number. The release tag is immutable.

If your first rc fails CI, fix the source and either force-push the
same `-rc1` tag or push a fresh `-rc2` (preference: bump for
clarity in the audit trail). Only push the plain release tag once
the corresponding rc has gone fully green AND has been verified on
a test host (e.g. PVE droste box for VM smoke testing).

Expect ~25-30 min on a cold kernel cache for the rc build; the
promote step is ~1-2 min (skopeo copy + draft edit, no rebuild).

## Downstream notification

The `promote` job's final step fires a `repository_dispatch` at
[`doctorjei/droste`](https://github.com/doctorjei/droste) with
`event_type=gemet-release` and `client_payload.tag=<the release tag>`.
Droste's workflow listens for that event and opens a pin-bump PR
against its own `main` (manual review on green CI — no auto-merge).

Activation: this step is conditional on a `DROSTE_DISPATCH_TOKEN`
secret being present under the repo's Actions secrets. The PAT
must be fine-grained, scoped to `doctorjei/droste` only, with
**Contents: Read and write** (for the PR branch droste opens) and
**Actions: Read and write** (dispatch permission). When the secret
is absent the step logs a `::warning ::` and no-ops; the release
itself still publishes. The step also runs with
`continue-on-error: true`, so a transient network or auth failure
during dispatch can't block the release either.

Only plain release tags (`v<ver>`) trigger the dispatch — rc tags
route through the `build-and-rc` job and never reach `promote`.

## Testing the pipeline without publishing

The release workflow also accepts `workflow_dispatch`. Running it via
the Actions UI (or `gh workflow run release.yml`) exercises every step
except GHCR push and release creation — a safe way to validate the
pipeline itself after workflow edits.

## Test tiers

Two automated tiers run on every release. The third is currently manual.

| Tier | What                                              | Runs where                | When                    |
|------|---------------------------------------------------|---------------------------|-------------------------|
| 1    | File inspection (kernel magic, initramfs cpio, `.txz` size, qcow2 validity, OCI rootfs structure, dpkg DB sanity) | `ubuntu-24.04` GH runner  | Every release + dispatch |
| 2    | systemd-in-OCI health (rootless podman boots yggdrasil's and bifrost's systemd; canopy structural check — no pid1) | `ubuntu-24.04` GH runner  | Every release + dispatch |
| 3    | Full VM boot (`scripts/ci-vm-boot-test.sh`: kernel + initramfs + virtiofs + qcow2 paths, systemd probe markers, bifrost SSH, failure-injection) | KVM-capable host          | Manual (pre-publish for draft releases) |

Tier 1 is `scripts/ci-structural-tests.sh`. Tier 2 splits across
`scripts/ci-systemd-test.sh` (yggdrasil), `scripts/ci-bifrost-test.sh`,
and `scripts/ci-canopy-test.sh`. Tier 3 is `scripts/ci-vm-boot-test.sh`
(shipped with v1.4.2) — it exercises the actual kernel + initramfs +
rootfs chain on a KVM host and is the pre-publish gate for draft
releases. Boot-path regressions (the class that hid behind v1.4.1's
qcow2-only smoke) are caught here. All scripts run locally with the
same arguments the workflow uses, so any CI failure reproduces without
pushing.
