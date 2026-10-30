#!/usr/bin/env bash
# Real LFM3-Omni video run on this Mac through the app's own video code
# (OmniVideoInput.swift, OmniVideoFeed.swift, LFM3Catalog.visionPrompt) and the
# b11960 runtime's macOS slice. Needs scripts/bootstrap_lfm3_omni_runtime.py and
# the two model files; downloads nothing.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models="${1:?usage: $0 <dir with LFM3-Omni-2B-Q4_0.gguf and mmproj-LFM3-Omni-2B-Q8_0.gguf> [video] [question] [max frames]}"
source_dir="$root/build/LFM3OmniNative/cache/llama.cpp-8642541b255bfb5dc39cd351a178be09013a55d6"
video="${2:-$source_dir/tools/mtmd/test-3.mp4}"
python3 "$root/scripts/bootstrap_lfm3_omni_runtime.py" --check
frameworks="$root/build/LFM3OmniNative/llama.xcframework/macos-arm64_x86_64"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -O -parse-as-library -D LFM3_EXPERIMENTAL -D LFM3_OMNI \
    -import-objc-header "$root/scripts/tests/omni-video-harness/llama-shim.h" \
    -F "$frameworks" -framework llama -Xlinker -rpath -Xlinker "$frameworks" \
    "$root/IOSLocalLLM/Services/LlamaCpp/OmniVideoInput.swift" \
    "$root/IOSLocalLLM/Services/LlamaCpp/OmniVideoFeed.swift" \
    "$root/IOSLocalLLM/Models/LFM3Catalog.swift" \
    "$root/scripts/tests/omni-video-harness/main.swift" \
    -o "$work/omni-video-harness"
"$work/omni-video-harness" "$models/LFM3-Omni-2B-Q4_0.gguf" "$models/mmproj-LFM3-Omni-2B-Q8_0.gguf" \
    "$video" "${@:3}"
