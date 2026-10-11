#!/usr/bin/env bash
# Model-free policy checks; no Core AI SDK or downloaded weights required.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf "$test_directory"' EXIT
mkdir -p "$test_directory/Sources/IOSLocalLLM" "$test_directory/Tests/PolicyTests"
cp "$repository_root/IOSLocalLLM/Services/MLXAssistantKVCachePolicy.swift" \
   "$repository_root/IOSLocalLLM/Services/ModelCheckpointCompatibility.swift" \
   "$repository_root/IOSLocalLLM/Services/ModelMemoryBudget.swift" \
   "$test_directory/Sources/IOSLocalLLM/"
cp "$repository_root/IOSLocalLLMTests/MLXQuantizationPolicyTests.swift" \
   "$test_directory/Tests/PolicyTests/"
cat > "$test_directory/Package.swift" <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "QuantizationPolicyChecks", targets: [
    .target(name: "IOSLocalLLM"),
    .testTarget(name: "PolicyTests", dependencies: ["IOSLocalLLM"]),
])
SWIFT
CLANG_MODULE_CACHE_PATH="$test_directory/module-cache" \
SWIFT_MODULE_CACHE_PATH="$test_directory/module-cache" \
swift test --package-path "$test_directory" --scratch-path "$test_directory/.build" \
    --cache-path "$test_directory/cache" --config-path "$test_directory/config" \
    --security-path "$test_directory/security" --disable-sandbox
