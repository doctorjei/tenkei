#!/usr/bin/env bash
#
# kernel-selftest — Validate gemet's shipped kernel-config opinions by
# booting a composed gemet image as a nested VM and asserting over SSH.
#
# Pulls the published gemet images for a version, composes
# <variant> + boot into a single bootable image, boots it as a nested
# VM via kento (usermode networking, host-port forward to guest :22),
# SSHes into the guest, and asserts the kernel-config opinions gemet
# ships in kernel/config/x86_64/gemet.conf:
#
#   kvm            /dev/kvm exists (KVM host drivers built in)
#   nbd            nbd in /proc/devices and /dev/nbd0 present
#   drbd           drbd in /proc/devices (builtin, major 147)
#   lsm            AppArmor active, SELinux not active in the LSM stack
#   selinux_quiet  no "Could not open policy file" in dmesg
#   evdev          at least one /dev/input/event* node
#   clean          no failed systemd units
#
# Exits 0 only if every required check passes.
#
# MUST run ON a KVM-capable host that has kento + podman installed
# (e.g. the cluster's nested-virt test VM). Lets gemet validate its own
# kernel opinions instead of relying on a downstream or a manual VM.
#
# Usage:
#   kernel-selftest.sh <version> [options]
#
#   <version>           required, image tag with no leading v
#                       (e.g. 1.7.2 or 1.7.2-rc1)
#   --variant <name>    rootfs variant to boot (default: bifrost).
#                       Must have working SSH for the probe.
#   --registry <ref>    image registry/namespace
#                       (default: ghcr.io/doctorjei/gemet)
#   --port <n>          host port forwarded to guest :22 (default: 10022)
#   --name <n>          kento instance name (default: gemet-selftest)
#   --memory <mb>       guest memory in MB (default: 1024)
#   --cores <n>         guest vCPU count (default: 2)
#   --keep              do not destroy the VM / remove the image on exit
#   -h, --help          this help
#
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────

VERSION=""
VARIANT="bifrost"
REGISTRY="ghcr.io/doctorjei/gemet"
PORT="10022"
NAME="gemet-selftest"
MEMORY="1024"
CORES="2"
KEEP="false"

# Populated as setup progresses so the trap can clean up partial state.
WORKDIR=""
IMAGE=""
VM_STARTED="false"

# ── Helpers ─────────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: kernel-selftest.sh <version> [options]

Boots a composed gemet image (<variant> + boot) as a nested VM via
kento on a KVM-capable host and asserts the shipped kernel-config
opinions over SSH.

Arguments:
  <version>           image tag, no leading v (e.g. 1.7.2 or 1.7.2-rc1)

Options:
  --variant <name>    rootfs variant (default: bifrost; needs SSH)
  --registry <ref>    registry/namespace (default: ghcr.io/doctorjei/gemet)
  --port <n>          host port -> guest :22 (default: 10022)
  --name <n>          kento instance name (default: gemet-selftest)
  --memory <mb>       guest memory in MB (default: 1024)
  --cores <n>         guest vCPU count (default: 2)
  --keep              keep the VM and image on exit
  -h, --help          show this help

Checks (all required): kvm, nbd, drbd, lsm, selinux_quiet, evdev, clean.
USAGE
    exit "${1:-1}"
}

# ── Argument parsing ────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)   VARIANT="${2:-}";  shift 2 ;;
        --registry)  REGISTRY="${2:-}"; shift 2 ;;
        --port)      PORT="${2:-}";     shift 2 ;;
        --name)      NAME="${2:-}";     shift 2 ;;
        --memory)    MEMORY="${2:-}";   shift 2 ;;
        --cores)     CORES="${2:-}";    shift 2 ;;
        --keep)      KEEP="true";       shift ;;
        -h|--help)   usage 0 ;;
        -*)          error "Unknown option '$1' (see --help)" ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$1"; shift
            else
                error "Unexpected argument '$1' (see --help)"
            fi
            ;;
    esac
done

[[ -n "$VERSION" ]] || { warn "version argument is required"; usage 1; }

# ── Cleanup ─────────────────────────────────────────────────────────

cleanup() {
    local rc=$?
    if [[ "$KEEP" == "true" ]]; then
        info "--keep set; leaving VM '${NAME}', image, and ${WORKDIR}"
        return "$rc"
    fi
    info "Cleaning up..."
    if [[ "$VM_STARTED" == "true" ]]; then
        kento vm stop "$NAME" >/dev/null 2>&1 || true
        kento vm destroy "$NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n "$IMAGE" ]]; then
        podman rmi -f "$IMAGE" >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORKDIR" ]]; then
        rm -rf "$WORKDIR" || true
    fi
    return "$rc"
}
trap cleanup EXIT

# ── Preconditions ───────────────────────────────────────────────────

if [[ ! -e /dev/kvm ]]; then
    error "/dev/kvm not found. kernel-selftest must run on a KVM-capable \
host with nested virtualization (e.g. the cluster's nested-virt test \
VM). A plain container or non-virt host cannot boot the nested guest."
fi

for cmd in kento podman ssh ssh-keygen timeout; do
    command -v "$cmd" >/dev/null 2>&1 || \
        error "Required command '${cmd}' not found on PATH. Install it \
(kento + podman are the host prerequisites) and retry."
done

# ── Compose ─────────────────────────────────────────────────────────

WORKDIR="$(mktemp -d)"
info "Workdir: ${WORKDIR}"

KEY="${WORKDIR}/key"
info "Generating ephemeral ed25519 keypair..."
ssh-keygen -t ed25519 -N "" -C "kernel-selftest" -f "$KEY" >/dev/null

IMAGE="localhost/${NAME}:${VERSION}"
CONTAINERFILE="${WORKDIR}/Containerfile"

cat > "$CONTAINERFILE" <<EOF
FROM ${REGISTRY}/boot:${VERSION} AS kernel
FROM ${REGISTRY}/${VARIANT}:${VERSION}
COPY --from=kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=kernel /boot/initramfs.img /boot/initramfs.img
EOF

info "Composing ${VARIANT}:${VERSION} + boot:${VERSION} -> ${IMAGE}"
podman build -t "$IMAGE" "$WORKDIR" || \
    error "podman build failed. Confirm ${REGISTRY}/{boot,${VARIANT}}:\
${VERSION} are published and pullable (gh auth / docker login to GHCR)."

# ── Launch ──────────────────────────────────────────────────────────

# --allow-nesting is required for the 'kvm' check: it tells kento to expose
# CPU virt extensions (-cpu host) to the guest. The gemet kernel has the KVM
# host drivers built in, but without exposed vmx/svm there is nothing for them
# to bind to, so /dev/kvm would not appear and the check would false-negative.
# (The host running this script must itself permit nested virt.)
info "Launching nested VM '${NAME}' (mem=${MEMORY}MB cores=${CORES})..."
kento vm run \
    --no-pve \
    --allow-nesting \
    --network usermode \
    --port "${PORT}:22" \
    --ssh-key "${KEY}.pub" \
    --ssh-host-keys \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --name "$NAME" \
    "$IMAGE" || \
    error "kento vm run failed to start '${NAME}'. Check kento + KVM \
availability on this host."
VM_STARTED="true"

# ── Wait for SSH ────────────────────────────────────────────────────

SSH_OPTS=(
    -p "$PORT"
    -i "$KEY"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=8
    -o LogLevel=ERROR
)

info "Waiting for guest SSH on port ${PORT} (allowing for boot)..."
sleep 25
ssh_up="false"
for attempt in $(seq 1 10); do
    if ssh -n "${SSH_OPTS[@]}" root@localhost true 2>/dev/null; then
        ssh_up="true"
        break
    fi
    info "  SSH not ready (attempt ${attempt}/10); retrying..."
    sleep 5
done

[[ "$ssh_up" == "true" ]] || \
    error "Guest SSH never became reachable on port ${PORT} after ~75s. \
The VM may have failed to boot or networking did not come up. Re-run \
with --keep and inspect 'kento vm' state."

# ── Remote checks ───────────────────────────────────────────────────

# Heredoc is quoted so it ships verbatim. The remote script does NOT use
# set -e: each check is evaluated independently and always prints its
# CHECK line so one failing command can't abort the rest. bifrost ships
# GNU coreutils, so standard tooling is fine.
read -r -d '' REMOTE_SCRIPT <<'REMOTE' || true
emit() { echo "CHECK $1 $2 $3"; }

# kvm: /dev/kvm exists and is a character device.
if [ -c /dev/kvm ]; then
    emit kvm PASS "$(ls -l /dev/kvm 2>/dev/null | head -1)"
else
    emit kvm FAIL "/dev/kvm missing or not a char device"
fi

# nbd: nbd in /proc/devices and /dev/nbd0 present.
if grep -qw nbd /proc/devices && [ -e /dev/nbd0 ]; then
    emit nbd PASS "nbd in /proc/devices, /dev/nbd0 present"
else
    emit nbd FAIL "nbd missing from /proc/devices or no /dev/nbd0"
fi

# drbd: drbd in /proc/devices (builtin, major 147).
if grep -qw drbd /proc/devices; then
    emit drbd PASS "$(grep -w drbd /proc/devices | head -1)"
else
    emit drbd FAIL "drbd missing from /proc/devices"
fi

# lsm: AppArmor active, SELinux not active in the LSM stack.
lsm_str="$(cat /sys/kernel/security/lsm 2>/dev/null)"
if echo "$lsm_str" | grep -qw apparmor && \
   ! echo "$lsm_str" | grep -qw selinux; then
    emit lsm PASS "lsm=${lsm_str}"
else
    emit lsm FAIL "lsm=${lsm_str:-<unreadable>}"
fi

# selinux_quiet: no "Could not open policy file" in dmesg.
policy_err="$(dmesg 2>/dev/null | grep -i 'could not open policy file')"
if [ -z "$policy_err" ]; then
    emit selinux_quiet PASS "no SELinux policy-file error in dmesg"
else
    emit selinux_quiet FAIL "$(echo "$policy_err" | head -1)"
fi

# evdev: at least one /dev/input/event* node.
ev="$(ls /dev/input/event* 2>/dev/null | head -1)"
if [ -n "$ev" ]; then
    emit evdev PASS "$ev"
else
    emit evdev FAIL "no /dev/input/event* nodes"
fi

# clean: no failed systemd units.
failed="$(systemctl --failed --no-legend 2>/dev/null)"
if [ -z "$failed" ]; then
    emit clean PASS "no failed units"
else
    emit clean FAIL "$(echo "$failed" | tr '\n' ';')"
fi
REMOTE

info "Running remote kernel-opinion checks over SSH..."
REMOTE_OUTPUT="$(ssh "${SSH_OPTS[@]}" root@localhost \
    "bash -s" <<< "$REMOTE_SCRIPT" 2>/dev/null || true)"

[[ -n "$REMOTE_OUTPUT" ]] || \
    error "Remote check script produced no output. SSH ran but the probe \
did not. Re-run with --keep and inspect the guest manually."

# ── Evaluate ────────────────────────────────────────────────────────

REQUIRED_CHECKS=(kvm nbd drbd lsm selinux_quiet evdev clean)
declare -A RESULTS=()

while IFS= read -r line; do
    [[ "$line" == CHECK\ * ]] || continue
    # CHECK <key> <PASS|FAIL> <detail...>
    rest="${line#CHECK }"
    key="${rest%% *}"
    rest="${rest#* }"
    status="${rest%% *}"
    detail="${rest#* }"
    RESULTS[$key]="$status"
    if [[ "$status" == "PASS" ]]; then
        echo -e "  \033[1;32mPASS\033[0m ${key}: ${detail}"
    else
        echo -e "  \033[1;31mFAIL\033[0m ${key}: ${detail}"
    fi
done <<< "$REMOTE_OUTPUT"

pass_count=0
fail_count=0
for key in "${REQUIRED_CHECKS[@]}"; do
    case "${RESULTS[$key]:-MISSING}" in
        PASS) pass_count=$((pass_count + 1)) ;;
        FAIL) fail_count=$((fail_count + 1)) ;;
        *)
            fail_count=$((fail_count + 1))
            echo -e "  \033[1;31mFAIL\033[0m ${key}: check did not run"
            ;;
    esac
done

echo ""
info "Summary: ${pass_count} passed, ${fail_count} failed \
(of ${#REQUIRED_CHECKS[@]} required)"

if [[ "$fail_count" -gt 0 ]]; then
    error "kernel-selftest FAILED: ${fail_count} required check(s) failed."
fi

info "kernel-selftest PASSED: all kernel-config opinions hold for \
${VARIANT}:${VERSION}."
