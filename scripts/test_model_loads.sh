#!/usr/bin/env bash
# Deterministic, model-free load/unload concurrency regressions.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf "$test_directory"' EXIT
mkdir -p "$test_directory/Sources/IOSLocalLLM" "$test_directory/Tests/LoadTests"
cp "$repository_root/IOSLocalLLM/Services/ModelLoadCoordinator.swift" \
   "$test_directory/Sources/IOSLocalLLM/"
# Compile the production lifetime type used by Lens/FastVLM. The remainder of
# its source file contains unrelated app presentation models requiring UIKit.
cat > "$test_directory/Sources/IOSLocalLLM/PresentationRequestLifetime.swift" <<'SWIFT'
import Foundation
SWIFT
sed -n '/^struct PresentationRequestLifetime: Equatable {/,/^}/p' \
    "$repository_root/IOSLocalLLM/Models/PresentationRequestLifetime.swift" \
    >> "$test_directory/Sources/IOSLocalLLM/PresentationRequestLifetime.swift"
cp "$repository_root/IOSLocalLLMTests/ModelLoadCoordinatorTests.swift" \
   "$test_directory/Tests/LoadTests/"
cat > "$test_directory/Package.swift" <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "ModelLoadChecks", targets: [
    .target(name: "IOSLocalLLM"),
    .testTarget(name: "LoadTests", dependencies: ["IOSLocalLLM"]),
])
SWIFT
CLANG_MODULE_CACHE_PATH="$test_directory/module-cache" \
SWIFT_MODULE_CACHE_PATH="$test_directory/module-cache" \
swift test --package-path "$test_directory" --scratch-path "$test_directory/.build" \
    --cache-path "$test_directory/cache" --config-path "$test_directory/config" \
    --security-path "$test_directory/security" --disable-sandbox
