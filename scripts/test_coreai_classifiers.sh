#!/usr/bin/env bash
# Run the host protocol tests without model weights or the device-only SDK.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/IOSLocalLLM" "$WORK/Tests/ClassifierTests"
cp "$ROOT/IOSLocalLLM/Services/CoreAIClassifierAdapter.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLM/Models/ClassifierCatalog.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLM/Models/SavedClassifierTask.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLMTests/ClassifierCatalogTests.swift" "$WORK/Tests/ClassifierTests/"
cp "$ROOT/IOSLocalLLM/Services/CoreAIClassifierWorkbench.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLM/Services/CoreAIInferenceError.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLM/Services/ClassifierResultExport.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLM/Services/Bridge/LocalClassifierAPI.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLM/Services/CoreAIModelStore.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLM/Models/CoreAIZooCatalog.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLM/Models/AppStoreModelPolicy.swift" "$WORK/Sources/IOSLocalLLM/"
cp "$ROOT/IOSLocalLLMTests/CoreAIClassifierAdapterTests.swift" "$WORK/Tests/ClassifierTests/"
cp "$ROOT/IOSLocalLLMTests/CoreAIClassifierWorkbenchTests.swift" "$WORK/Tests/ClassifierTests/"
cp "$ROOT/IOSLocalLLMTests/CoreAIModelStoreTests.swift" "$WORK/Tests/ClassifierTests/"
# Exercise the production store/catalog with only the unrelated app services
# stubbed. No model runtime or downloaded weights are part of this harness.
cat > "$WORK/Sources/IOSLocalLLM/HostStubs.swift" <<'SWIFT'
import Foundation
enum ModelCapability: Hashable, Sendable { case thinking, tools, vision }
enum ModelRuntime: Sendable { case mlx, llamaCpp, coreAI }
struct AssistantModel: Sendable {
    let id: String
    let repoID: String
    let displayName: String
    let subtitle: String
    let approxRAMBytes: Int64
    let tags: [String]
    let contextWindowTokens: Int
    var downloadSizeBytes: Int64? = nil
    var capabilities: Set<ModelCapability> = []
    var supportsTools: Bool = false
    var runtime: ModelRuntime = .mlx
}
@MainActor enum MemoryAdvisor { static func invalidateFootprintCache() {} }
SWIFT
cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "ClassifierChecks", platforms: [.macOS(.v13)], targets: [
    .target(name: "IOSLocalLLM"),
    .testTarget(name: "ClassifierTests", dependencies: ["IOSLocalLLM"])
])
SWIFT
CLANG_MODULE_CACHE_PATH="$WORK/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$WORK/ModuleCache" \
    swift test --package-path "$WORK" --disable-sandbox \
    --cache-path "$WORK/cache" --config-path "$WORK/config" --security-path "$WORK/security"
