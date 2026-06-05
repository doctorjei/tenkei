#!/usr/bin/env bash
#
# build-kernel — Build a kernel for tenkei using upstream Kata configs
#
# Wraps upstream/kernel/build-kernel.sh for standalone use outside the
# kata-containers monorepo. Provides the shim scripts that the upstream
# builder expects but that aren't in our subtree import.
#
# Usage:
#   build-kernel.sh <version> [setup|build|install]
#   build-kernel.sh 6.18.15 setup    — download and configure kernel source
#   build-kernel.sh 6.18.15 build    — build the kernel
#   build-kernel.sh 6.18.15 install  — copy vmlinuz + initramfs to build/
#   build-kernel.sh 6.18.15          — setup + build + install (default)
#
# The install step also builds the initramfs if it doesn't exist yet.
# Output goes to build/ in the repo root:
#   build/vmlinuz              — compressed kernel
#   build/gemet-initramfs.img — initramfs with busybox + virtiofs init
#
# Environment:
#   KERNEL_ARCH     — target architecture (default: x86_64)
#   BUILD_JOBS      — parallel make jobs (default: nproc)
#
# Build dependencies (Debian/Ubuntu):
#   apt install build-essential flex bison bc libelf-dev libssl-dev
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPSTREAM_KERNEL="${REPO_ROOT}/upstream/kernel"

# ─── Helpers ───────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: build-kernel.sh <version> [setup|build|install]

Arguments:
  version   Kernel version (e.g., 6.18.15, 6.1.75)
  command   setup  — download and configure kernel source
            build  — compile the kernel
            install — copy vmlinuz + initramfs to build/
            (default: setup + build + install)

Output (after install):
  build/vmlinuz              Compressed kernel image
  build/gemet-initramfs.img Initramfs (busybox + virtiofs init)

Note: run all steps from the same directory — the kernel source is
placed in the current working directory by the upstream script.

Build dependencies (Debian/Ubuntu):
  apt install build-essential flex bison bc libelf-dev libssl-dev busybox-static
USAGE
    exit 1
}

# ─── Create shim scripts ──────────────────────────────────────────

# The upstream build-kernel.sh sources tools/packaging/scripts/lib.sh
# and calls tools/packaging/scripts/apply_patches.sh. These don't
# exist in our subtree import, so we create temporary shims.

create_shims() {
    local shim_dir="$1"

    mkdir -p "$shim_dir"

    # lib.sh shim — provides functions the upstream script expects
    cat > "${shim_dir}/lib.sh" <<'SHIMLIB'
# tenkei shim for kata packaging lib.sh
# Provides minimal stubs so upstream build-kernel.sh can run standalone.

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
OK()   { echo "[OK] $*" >&2; }
warning() { echo "WARNING: $*" >&2; }

check_program() { type "$1" >/dev/null 2>&1; }

# Stub: we always pass -v <version> so this should never be called.
# If it is, fail loudly.
get_from_kata_deps() {
    die "get_from_kata_deps called but no versions.yaml exists." \
        "Pass kernel version explicitly with -v."
}
SHIMLIB

    # apply_patches.sh — applies .patch files from a directory
    cat > "${shim_dir}/apply_patches.sh" <<'SHIMPATCH'
#!/usr/bin/env bash
# tenkei shim for kata apply_patches.sh
set -euo pipefail

patches_dir="${1:-}"
[ -d "$patches_dir" ] || { echo "INFO: No patches dir: ${patches_dir}"; exit 0; }

shopt -s nullglob
patches=("${patches_dir}"/*.patch)
shopt -u nullglob

if [ ${#patches[@]} -eq 0 ]; then
    echo "INFO: No patches to apply in ${patches_dir}"
    exit 0
fi

for patch in "${patches[@]}"; do
    echo "INFO: Applying $(basename "$patch")"
    git apply "$patch" || {
        echo "ERROR: Failed to apply $(basename "$patch")" >&2
        exit 1
    }
done
SHIMPATCH
    chmod +x "${shim_dir}/apply_patches.sh"
}

# ─── Install artifacts ─────────────────────────────────────────────

apply_gemet_overlay() {
    local ver="$1"
    local karch="$2"
    local config_version
    config_version="$(cat "${UPSTREAM_KERNEL}/kata_config_version")"

    local kernel_path="${PWD}/kata-linux-${ver}-${config_version}"
    [[ -d "$kernel_path" ]] || error "Kernel source not found: ${kernel_path}" \
        "— overlay step expects upstream setup to have completed first."

    # Apply gemet config overlay on top of Kata's fragments
    local gemet_frag="${REPO_ROOT}/kernel/config/${karch}/gemet.conf"
    if [[ -f "$gemet_frag" ]]; then
        info "Applying gemet config overlay: $(basename "$gemet_frag")"
        (
            cd "$kernel_path"
            bash scripts/kconfig/merge_config.sh -m .config "$gemet_frag"
            make olddefconfig
        )
        # merge_config.sh -m (merge-only mode) skips its final validation,
        # and `make olddefconfig` silently drops any symbol whose deps are
        # unmet. Assert every CONFIG_*= line from the overlay survived into
        # the final .config so a dropped or renamed symbol fails the build
        # loudly instead of silently shipping a kernel missing the opinion.
        local missing=0 cfgline
        while IFS= read -r cfgline; do
            [[ "$cfgline" =~ ^CONFIG_[A-Z0-9_]+=. ]] || continue
            grep -qxF "$cfgline" "${kernel_path}/.config" \
                || { echo "ERROR: gemet overlay symbol dropped from final .config: $cfgline" >&2; missing=1; }
        done < "$gemet_frag"
        [[ "$missing" -eq 0 ]] || error \
            "gemet kernel overlay symbols were dropped by olddefconfig (unmet deps or renamed symbol)." \
            "Inspect kernel/config/${karch}/gemet.conf and add the missing dependency, or correct the symbol name."
    else
        info "No gemet fragment for arch=${karch}; using Kata config as-is"
    fi
}

install_tenkei() {
    local ver="$1"
    local karch="$2"
    local config_version
    config_version="$(cat "${UPSTREAM_KERNEL}/kata_config_version")"

    local kernel_path="${PWD}/kata-linux-${ver}-${config_version}"
    local build_dir="${REPO_ROOT}/build"

    # Find bzImage
    local bzimage="${kernel_path}/arch/x86/boot/bzImage"
    if [[ "$karch" == "aarch64" || "$karch" == "arm64" ]]; then
        bzimage="${kernel_path}/arch/arm64/boot/Image.gz"
        warn "ARM64 kernel built — note that test-boot.sh only supports x86_64"
    fi

    [[ -f "$bzimage" ]] || error "Kernel not found: ${bzimage}" \
        "— run 'build-kernel.sh ${ver} build' first." \
        "Ensure all steps (setup, build, install) run from the same directory."

    # Build initramfs if needed
    local initramfs="${REPO_ROOT}/initramfs/gemet-initramfs.img"
    if [[ ! -f "$initramfs" ]]; then
        info "Building initramfs..."
        bash "${REPO_ROOT}/initramfs/build.sh"
    fi
    [[ -f "$initramfs" ]] || error "Initramfs not found: ${initramfs}"

    # Copy to build/
    mkdir -p "$build_dir"
    cp "$bzimage" "${build_dir}/vmlinuz"
    cp "$initramfs" "${build_dir}/gemet-initramfs.img"

    info "Installed to ${build_dir}/"
    info "  vmlinuz              $(du -h "${build_dir}/vmlinuz" | cut -f1)"
    info "  gemet-initramfs.img $(du -h "${build_dir}/gemet-initramfs.img" | cut -f1)"
}

# ─── Main ──────────────────────────────────────────────────────────

[[ $# -ge 1 ]] || usage

version="$1"
subcmd="${2:-all}"

# Validate version looks sane
[[ "$version" =~ ^[0-9]+\.[0-9]+ ]] || error "Invalid kernel version: ${version}"

arch="${KERNEL_ARCH:-x86_64}"

info "Tenkei kernel build"
info "  Version: ${version}"
info "  Arch:    ${arch}"
info "  Command: ${subcmd}"

# Create shim directory where upstream expects its scripts
# upstream/kernel/build-kernel.sh sets:
#   packaging_scripts_dir="${script_dir}/../scripts"
# So it looks for upstream/scripts/ — we create shims there.
shim_dir="${UPSTREAM_KERNEL}/../scripts"
shim_dir="$(cd "$(dirname "$shim_dir")" && pwd)/scripts"

# Always (re)create shims to avoid stale files from interrupted runs.
# Track whether we created the directory so cleanup knows what to remove.
shim_dir_created=false
if [[ ! -d "$shim_dir" ]]; then
    shim_dir_created=true
fi

info "Creating shim scripts in ${shim_dir}"
create_shims "$shim_dir"

cleanup() {
    rm -f "${shim_dir}/lib.sh" "${shim_dir}/apply_patches.sh"
    if [[ "$shim_dir_created" == "true" ]]; then
        # Remove the directory only if we created it
        rmdir "$shim_dir" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Run the upstream build script
case "$subcmd" in
    setup)
        info "Setting up kernel source..."
        bash "${UPSTREAM_KERNEL}/build-kernel.sh" \
            -v "$version" -a "$arch" setup
        apply_gemet_overlay "$version" "$arch"
        ;;
    build)
        config_version="$(cat "${UPSTREAM_KERNEL}/kata_config_version")"
        kernel_path="${PWD}/kata-linux-${version}-${config_version}"
        [[ -d "$kernel_path" ]] || error "Kernel source not found: ${kernel_path}" \
            "— did you run 'setup' from a different directory? All steps must run from the same CWD."
        info "Building kernel..."
        bash "${UPSTREAM_KERNEL}/build-kernel.sh" \
            -v "$version" -a "$arch" build
        ;;
    install)
        install_tenkei "$version" "$arch"
        ;;
    all)
        info "Setting up kernel source..."
        bash "${UPSTREAM_KERNEL}/build-kernel.sh" \
            -v "$version" -a "$arch" setup
        apply_gemet_overlay "$version" "$arch"
        info "Building kernel..."
        bash "${UPSTREAM_KERNEL}/build-kernel.sh" \
            -v "$version" -a "$arch" build
        install_tenkei "$version" "$arch"
        ;;
    *)
        usage
        ;;
esac

info "Done."
