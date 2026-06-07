# Bifrost

Bifrost is Gemet's SSH-ready companion image, built directly on top of
Yggdrasil. Where Yggdrasil is a pure foundation (no SSH host keys, sshd
disabled, no authorized_keys machinery), Bifrost re-adds an opinionated
SSH layer suitable for humans and ad-hoc testing — generated host keys
at first boot, sshd enabled, and a `/etc/bifrost/authorized_keys` staging
path for pre-boot key injection.

Bifrost is a derived image: `rootfs/build-bifrost.sh` extracts an
existing `yggdrasil-<ver>.txz`, overlays the bifrost bits, and
re-packages as .txz / qcow2 / OCI. No `podman build` dependency —
the overlay is plain file installs plus `systemctl enable`-equivalent
symlinks, executed inside an unprivileged user namespace.

## What it is

Everything Yggdrasil ships, plus:

- `openssh-server` **enabled** (`ssh.service` + `ssh.socket` wired into
  `multi-user.target.wants` / `sockets.target.wants`)
- SSH host keys **generated at first boot** via
  `bifrost-hostkeys.service` (oneshot running `ssh-keygen -A`,
  idempotent across reboots)
- `/etc/bifrost/authorized_keys` staging path and
  `bifrost-sshkey-sync.service` that merges any staged keys into
  `/root/.ssh/authorized_keys` once per boot (non-destructive)

Bifrost does not strip anything Yggdrasil kept. The BusyBox swap,
targeted purges, doc/locale/man sweep, and Python library trim
described in [yggdrasil.md](yggdrasil.md) all apply transitively.

## SSH host keys

Bifrost ships **no** pre-generated `/etc/ssh/ssh_host_*_key` files in
the image. Baking in keys would let anyone with the published image
impersonate every deployment. Instead, keys are generated at first
boot by `bifrost-hostkeys.service`:

```ini
[Unit]
Description=Generate SSH host keys if missing
Before=ssh.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
```

`ssh-keygen -A` only creates host keys that don't already exist, so
the unit is safe to run on every boot — after the first boot it's a
no-op. The ordering (`Before=ssh.service`) guarantees the sshd daemon
never starts before keys are in place. It deliberately does *not*
order before `ssh.socket`: the socket merely listens (it needs no key
material to bind), and ordering a `multi-user`-wanted service before
`ssh.socket` closes a dependency cycle
(`ssh.socket`→`sockets.target`→`basic.target`→ this service →
`ssh.socket`) that systemd resolves by dropping `sockets.target` —
fixed in v1.7.0.

Debian's openssh-server also ships its own `sshd-keygen.service`
(`ConditionFirstBoot=yes`, also runs `ssh-keygen -A`) which is wanted
by ssh.service. Bifrost's unit is an independent belt-and-braces:
both are idempotent, either alone suffices, and running both costs
nothing.

## SSH authorized_keys sync

Bifrost includes a simple first-boot key-injection path for
orchestrators (humans, droste, kento test fixtures): stage pubkey
lines at `/etc/bifrost/authorized_keys` before starting the VM or
container, and `bifrost-sshkey-sync.service` will merge them into
`/root/.ssh/authorized_keys` on boot.

### Contract

- **Source:** `/etc/bifrost/authorized_keys` (configurable via
  `BIFROST_SSHKEY_SOURCE`)
- **Target:** `/root/.ssh/authorized_keys` (configurable via
  `BIFROST_SSHKEY_TARGET`)
- **Merge semantics:** exact-line fixed-string dedup (`grep -Fx`).
  Non-destructive — existing keys in the target are never removed or
  rewritten. A user can add their own keys manually and those survive
  across boots.
- **Idempotent:** running the unit repeatedly is safe and produces no
  duplicate lines.
- **Comments + blanks:** source lines that are empty or begin with `#`
  are skipped.
- **Condition:** the unit has
  `ConditionPathExists=/etc/bifrost/authorized_keys`, so it's a no-op
  if no keys are staged.

### Unit ordering

```ini
[Unit]
Before=ssh.service
After=local-fs.target
```

Soft ordering — if ssh.service isn't scheduled for some reason, the
sync still runs. (Ordered before `ssh.service` only, not `ssh.socket`
— see the host-keys section for why ordering before the socket would
create a dependency cycle.) The unit is `WantedBy=multi-user.target`, so it
fires during normal boot regardless of sshd state.

## Usage

### Inject a key pre-boot

From an orchestrator, place a line in `/etc/bifrost/authorized_keys`
before starting the VM/container:

```bash
# Example: write your pubkey into a bifrost qcow2 via guestfish, or
# mount the rootfs and drop a file. Method is orchestrator-specific.
echo "ssh-ed25519 AAAAC3... me@laptop" \
    > /etc/bifrost/authorized_keys
```

On first boot, `bifrost-sshkey-sync.service` merges the line into
`/root/.ssh/authorized_keys`. `bifrost-hostkeys.service` generates
the host keys. `ssh.service` starts. You can SSH in as `root`.

### SSH in

```bash
ssh root@<vm-ip>
```

(Password auth is disabled by Debian's default sshd_config; pubkey is
the only path in.)

## Build

```bash
bash rootfs/build-bifrost.sh              # build everything (reads VERSION)
bash rootfs/build-bifrost.sh 1.2.0        # build for an explicit version
bash rootfs/build-bifrost.sh --no-qcow2   # skip disk image
bash rootfs/build-bifrost.sh --no-import  # skip OCI import + archive
```

**Prerequisite:** `build/yggdrasil-<version>.txz` must already exist
(produced by `bash rootfs/build-yggdrasil.sh`). Bifrost is a derived
image — it extracts the Yggdrasil tarball as its base, overlays the
bifrost bits, and re-packages. If the tarball is missing the build
script hard-fails with a pointer back to this prerequisite.

The same flag family as `build-yggdrasil.sh`: `--no-import`, `--no-txz`,
`--no-qcow2`. Any combination is valid.

### Artifact forms

`build-bifrost.sh` produces up to three artifacts:

- `build/bifrost-<ver>.txz` — rootfs tarball (xz-compressed)
- `build/bifrost-<ver>.qcow2` — partition-less ext4 disk image (same
  layout as yggdrasil's qcow2; boot with
  `root=/dev/vda rootfstype=ext4`)
- `build/bifrost-<ver>-oci.tar` — OCI archive (imported as
  `bifrost:<ver>` and then `podman save --format=oci-archive`)

In container build environments with restricted newuidmap, rootless
podman import fails; the build script treats that as a warning and
continues with .txz + qcow2. Published releases run in CI where
rootless podman works.

## Downstream consumption

If you want an SSH-ready image with exactly Bifrost's policy, use
`bifrost:<ver>` directly.

If you want a different user model (different target username, custom
`authorized_keys` path, key policy hooked into a different
orchestration plane, etc.), build `FROM yggdrasil:<ver>` and install
your own variant. Bifrost is an opinionated layer by design — it is
not a base for further SSH-policy customization.

For Gemet's companion projects:

- **droste** — builds `FROM yggdrasil:<ver>`, not Bifrost. Tiers own
  their own user model.
- **kento test fixtures** — same; each fixture builds on Yggdrasil.
- **Human ad-hoc testing, scratch VMs, cluster bootstrap tests** —
  Bifrost is the right default.

---

*Last updated: 2026-04-24 (Gemet 1.5.1 — namespace switch, bifrost-hostkeys Condition removal)*
