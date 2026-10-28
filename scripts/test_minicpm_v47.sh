#!/usr/bin/env bash
# Model-free catalog, prompt, and execution-policy regressions on macOS.
set -euo pipefail
minicpm_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--lfm3-experimental" && $# -eq 1 ]]; then
    set -- -Xswiftc -DLFM3_EXPERIMENTAL
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--lfm3-experimental]" >&2
    exit 64
else
    set --
fi
minicpm_work="$(mktemp -d)"
trap 'rm -rf "$minicpm_work"' EXIT
xcrun clang++ -std=c++17 "$minicpm_root/scripts/tests/MiniCPMTokenBudgetChecks.cpp" \
    -o "$minicpm_work/token-budget-checks"
"$minicpm_work/token-budget-checks"
mkdir -p "$minicpm_work/Sources/IOSLocalLLM" "$minicpm_work/Tests/MiniCPMTests"
cp "$minicpm_root/IOSLocalLLM/Models/MiniCPMV47Catalog.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/IOSLocalLLM/Models/LFM3Catalog.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/IOSLocalLLM/Services/Runtime/MiniCPMV47/MiniCPMV47Artifacts.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/IOSLocalLLM/Services/Runtime/MiniCPMV47/MiniCPM35BTextProfile.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/IOSLocalLLM/Services/ConversationTitler.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/scripts/tests/ConversationTitlerHostStubs.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/scripts/tests/ConversationTitlerHostTests.swift" "$minicpm_work/Tests/MiniCPMTests/"
python3 "$minicpm_root/scripts/tests/extract_minicpm_context_contracts.py" \
    "$minicpm_root" "$minicpm_work/Sources/IOSLocalLLM" "$minicpm_work/Tests/MiniCPMTests"
cp "$minicpm_root/IOSLocalLLM/Models/ChatTemplate.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/IOSLocalLLM/Models/LFM3ToolProtocol.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/IOSLocalLLM/Services/AssistantToolCallParser.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/scripts/tests/LFM3ToolHostStubs.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/IOSLocalLLMTests/LFM3ToolCallingTests.swift" "$minicpm_work/Tests/MiniCPMTests/"
cp "$minicpm_root/IOSLocalLLM/Models/AssistantOutputSanitizer.swift" "$minicpm_work/Sources/IOSLocalLLM/"
cp "$minicpm_root/IOSLocalLLMTests/MiniCPMConversationContextTests.swift" "$minicpm_work/Tests/MiniCPMTests/"
# The service also contains UIKit/Combine/native runtime dependencies. Compile
# its actual, Foundation-only profile contract with the catalog on the host.
sed -n '/^struct LlamaCppVLMExecutionProfile: Equatable, Sendable {/,/^}/p' \
    "$minicpm_root/IOSLocalLLM/Services/LlamaCpp/LlamaCppVLMService.swift" \
    > "$minicpm_work/Sources/IOSLocalLLM/LlamaCppVLMExecutionProfile.swift"
cp "$minicpm_root/IOSLocalLLMTests/MiniCPMV47CatalogTests.swift" "$minicpm_work/Tests/MiniCPMTests/"
cp "$minicpm_root/IOSLocalLLMTests/LFM3CatalogTests.swift" "$minicpm_work/Tests/MiniCPMTests/"
cp "$minicpm_root/IOSLocalLLMTests/MiniCPMV47ArtifactTests.swift" "$minicpm_work/Tests/MiniCPMTests/"
cp "$minicpm_root/IOSLocalLLMTests/MiniCPM35BTextProfileTests.swift" "$minicpm_work/Tests/MiniCPMTests/"
cat > "$minicpm_work/Package.swift" <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "MiniCPMChecks", platforms: [.macOS(.v14)], targets: [
    .target(name: "IOSLocalLLM"),
    .testTarget(name: "MiniCPMTests", dependencies: ["IOSLocalLLM"])
])
SWIFT
CLANG_MODULE_CACHE_PATH="$minicpm_work/module-cache" \
SWIFT_MODULE_CACHE_PATH="$minicpm_work/module-cache" \
swift test --package-path "$minicpm_work" --scratch-path "$minicpm_work/.build" \
    --cache-path "$minicpm_work/cache" --config-path "$minicpm_work/config" \
    --security-path "$minicpm_work/security" --disable-sandbox "$@"
