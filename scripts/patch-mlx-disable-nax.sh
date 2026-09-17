#!/bin/sh

set -eu

# NAX A/B helper (developer-only, opt-in — never wired into the build).
#
# MLX selects neural-accelerator ("nax", Metal 4 TensorOps) kernels for
# phone-class GPUs at gen >= 18 with iOS >= 26.2 — iPhone 17 Pro Max
# (applegpu_g18p) is inside that regime. To attribute a performance or
# numerics difference, build one arm with the gate forced off.
#
# This edits the RESOLVED mlx-swift checkout (same mechanism as
# scripts/patch-mlx-metal-warning.sh) and is idempotent:
#
#   ./scripts/patch-mlx-disable-nax.sh status     # show current gate state
#   ./scripts/patch-mlx-disable-nax.sh disable    # NAX-off A/B build arm
#   ./scripts/patch-mlx-disable-nax.sh enable     # restore the stock gate
#
# The checkout resolves from an explicit path argument, then
# $MLX_SWIFT_CHECKOUT, then Xcode's $BUILD_DIR (scheme environment), then
# the newest DerivedData candidate. After toggling, clean-build the Cmlx
# target (Xcode: Product > Clean Build Folder) before measuring.
#
# See Docs/EDGE0_PERF_UPDATE_SCAN_2026-09-17.md for the measurement recipe.

usage() {
    /bin/cat <<'EOF'
usage: patch-mlx-disable-nax.sh disable|enable|status [checkout-path]

  disable   Force MLX's is_nax_available() to false.
  enable    Restore the stock NAX gate condition.
  status    Print the gate state for the resolved checkout.

checkout-path: optional path to the resolved mlx-swift checkout
               (default: $MLX_SWIFT_CHECKOUT, Xcode $BUILD_DIR, DerivedData)
EOF
}

mode="${1:-}"
checkout="${2:-${MLX_SWIFT_CHECKOUT:-}}"

if [ -z "$mode" ] || [ "$mode" = "-h" ] || [ "$mode" = "--help" ]; then
    usage
    exit 2
fi

resolve_from_repo_build() {
    script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    repo_root=$(dirname "$script_dir")
    best=""
    best_time=0
    for build_dir in "$repo_root"/build/*/; do
        [ -d "$build_dir" ] || continue
        candidate="${build_dir%/}/SourcePackages/checkouts/mlx-swift"
        [ -f "$candidate/Source/Cmlx/mlx/mlx/backend/metal/device.h" ] || continue
        stamp=$(/usr/bin/stat -f %m "${build_dir%/}" 2>/dev/null || echo 0)
        if [ "$stamp" -gt "$best_time" ]; then
            best="$candidate"
            best_time="$stamp"
        fi
    done
    printf '%s' "$best"
}

resolve_from_derived_data() {
    best=""
    best_time=0
    for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/OnDeviceCoreAIStudio-*/SourcePackages/checkouts/mlx-swift; do
        [ -d "$candidate" ] || continue
        [ -f "$candidate/Source/Cmlx/mlx/mlx/backend/metal/device.h" ] || continue
        stamp=$(/usr/bin/stat -f %m "$candidate" 2>/dev/null || echo 0)
        if [ "$stamp" -gt "$best_time" ]; then
            best="$candidate"
            best_time="$stamp"
        fi
    done
    printf '%s' "$best"
}

if [ -z "$checkout" ]; then
    if [ -n "${BUILD_DIR:-}" ]; then
        checkout="${BUILD_DIR%%/Build/*}/SourcePackages/checkouts/mlx-swift"
    else
        checkout=$(resolve_from_repo_build)
        if [ -z "$checkout" ]; then
            checkout=$(resolve_from_derived_data)
        fi
    fi
fi

source_file="${checkout:-}/Source/Cmlx/mlx/mlx/backend/metal/device.h"
marker="IOSLocalLLM NAX A/B arm (disable)"

if [ -z "$checkout" ] || [ ! -f "$source_file" ]; then
    echo "error: mlx-swift checkout not found under '${checkout:-<unresolved>}'" >&2
    echo "hint: pass the checkout path explicitly: $0 $mode /path/to/mlx-swift" >&2
    exit 1
fi

gate_state() {
    if /usr/bin/grep -Fq "$marker" "$source_file"; then
        echo disabled
    else
        echo enabled
    fi
}

case "$mode" in
status)
    echo "checkout: $source_file"
    echo "NAX gate: $(gate_state)"
    ;;
disable)
    if [ "$(gate_state)" = disabled ]; then
        echo "NAX gate already disabled; nothing to do."
        exit 0
    fi
    /usr/bin/perl -0pi -e \
        's/(#ifdef MLX_METAL_NO_NAX\n  return false;\n#else\n)/$1  return false; \/\/ IOSLocalLLM NAX A\/B arm (disable)\n/' \
        "$source_file"
    if [ "$(gate_state)" != disabled ]; then
        echo "error: patch did not apply; mlx-swift layout changed?" >&2
        exit 1
    fi
    echo "NAX gate disabled in: $source_file"
    echo "Now: Product > Clean Build Folder, rebuild, install, and measure."
    echo "Restore afterwards with: $0 enable"
    ;;
enable)
    if [ "$(gate_state)" = enabled ]; then
        echo "NAX gate already enabled (stock); nothing to do."
        exit 0
    fi
    /usr/bin/perl -0pi -e \
        's/\n  return false; \/\/ IOSLocalLLM NAX A\/B arm \(disable\)//' \
        "$source_file"
    if [ "$(gate_state)" != enabled ]; then
        echo "error: restore did not apply; inspect $source_file" >&2
        exit 1
    fi
    echo "NAX gate restored to the stock condition in: $source_file"
    echo "Now: Product > Clean Build Folder and rebuild."
    ;;
*)
    usage
    exit 2
    ;;
esac
