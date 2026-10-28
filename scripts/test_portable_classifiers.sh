#!/usr/bin/env bash
# Compile the production portable adapters on Mac; live checks are opt-in and
# use existing model folders. This script never downloads model weights.
set -euo pipefail
classifier_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
classifier_work="$classifier_root/build/classifier-audit/PortableRuntimeChecks"
mkdir -p "$classifier_work/Sources/IOSLocalLLM" "$classifier_work/Tests/ClassifierTests"
for source in CoreAIClassifierAdapter CoreAIClassifierTokenizer CoreAIClassifierWorkbench CoreAIInferenceError PortableClassifierRuntime GGUFDecisionClassifierRuntime ClassifierResultExport; do
  cp "$classifier_root/IOSLocalLLM/Services/$source.swift" "$classifier_work/Sources/IOSLocalLLM/"
done
cp "$classifier_root/IOSLocalLLM/Models/ClassifierCatalog.swift" "$classifier_root/IOSLocalLLM/Models/SavedClassifierTask.swift" "$classifier_work/Sources/IOSLocalLLM/"
cp "$classifier_root/IOSLocalLLMTests/PortableClassifierRuntimeTests.swift" "$classifier_work/Tests/ClassifierTests/"
python3 - "$classifier_root" "$classifier_work" <<'PY'
import json,os,sys
from pathlib import Path
root,work=map(Path,sys.argv[1:])
checkout=os.environ.get('CLASSIFIER_TOKENIZER_CHECKOUT')
dependency='.package(path: '+json.dumps(checkout)+')' if checkout else '.package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3")'
dependency += ', .package(url: "https://github.com/apple/swift-collections", exact: "1.6.0")'
checkouts=os.environ.get('CLASSIFIER_DEPENDENCY_CHECKOUTS')
if checkouts:
    names=['swift-transformers','swift-collections','swift-crypto','swift-asn1','swift-huggingface','swift-jinja','yyjson']
    dependency=', '.join('.package(path: '+json.dumps(str(Path(checkouts)/name))+')' for name in names)
if not (work/'llama.xcframework').exists():
    (work/'llama.xcframework').symlink_to(root/'build/ClassifierNative/llama.xcframework', target_is_directory=True)
(work/'Package.swift').write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "PortableClassifierChecks", platforms: [.macOS("15.0")], dependencies: ['''+dependency+'''], targets: [
  .binaryTarget(name: "llama", path: "llama.xcframework"),
  .target(name: "IOSLocalLLM", dependencies: ["llama", .product(name: "Hub", package: "swift-transformers"), .product(name: "Tokenizers", package: "swift-transformers")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", '''+json.dumps(str(root/'build/ClassifierNative/llama.xcframework/macos-arm64_x86_64'))+'''])]),
  .testTarget(name: "ClassifierTests", dependencies: ["IOSLocalLLM"])
])
''')
PY
swift build --build-tests --package-path "$classifier_work" --disable-sandbox \
  --cache-path "$classifier_root/build/classifier-audit/swift-cache" \
  --config-path "$classifier_work/config" --security-path "$classifier_work/security"
# Run the bundle directly: Swift Build's package reporter can omit the final
# XCTest summary after Core ML emits system-service diagnostics.
xcrun xctest "$classifier_work/.build/out/Products/Debug/ClassifierTests.xctest"
