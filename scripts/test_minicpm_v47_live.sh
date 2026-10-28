#!/usr/bin/env bash
# Run the production Swift GGUF bridge against an already-downloaded 1B pair
# on Apple silicon macOS. Never downloads weights or prints model output.
set -euo pipefail
minicpm_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
minicpm_models="${1:?Usage: test_minicpm_v47_live.sh /path/to/pinned/1B/model}"
minicpm_framework="$minicpm_root/build/ClassifierNative/llama.xcframework/macos-arm64_x86_64"
minicpm_work="$(mktemp -d)"
trap 'rm -rf "$minicpm_work"' EXIT
python3 - "$minicpm_root" "$minicpm_work" <<'PY'
import re, sys
from pathlib import Path
root, work = map(Path, sys.argv[1:])
bridge = (root / 'IOSLocalLLM/Services/LlamaCpp/LlamaCppBridge.swift').read_text()
# A CGImage-backed fixture replaces UIImage on the Mac host. Image conversion,
# prompt construction, native inference, cancellation and cleanup stay intact.
bridge = bridge.replace('import UIKit\n', 'import Foundation\nimport CoreGraphics\n')
(work / 'LlamaCppBridge.swift').write_text(bridge)
assistant = (root / 'IOSLocalLLM/Services/CodingAssistantService.swift').read_text()
prefix = re.search(r'^enum GGUFPrefixCache \{.*?^\}', assistant, re.M | re.S).group()
(work / 'GGUFPrefixCache.swift').write_text(prefix + '\n')
PY
cat > "$minicpm_work/Bridge.h" <<'HEADER'
#include "llama.h"
#include "ggml.h"
#include "mtmd.h"
#include "mtmd-helper.h"
HEADER
cat > "$minicpm_work/Fixtures.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import CoreImage

struct UIImage {
    let cgImage: CGImage?
    var ciImage: CIImage? { nil }
}
struct Diagnostics {
    static let shared = Diagnostics()
    func breadcrumb(_ message: String, category: String) {}
}
// The ordinary 1B bridge must never opt into the 35B streaming engine.
// Actual 35B text and vision are exercised by test_minicpm_v47_35b_live.sh.
final class MiniCPMV47StreamingVLM {
    init(directory: URL, contextSize: UInt32, textOnly: Bool = false, cacheSlots: UInt32 = 16) throws { throw LlamaCppError.unsupportedModel(MiniCPMV47Catalog.streaming35BRequirement) }
    func cancelCurrent() {}
    func generateText(prompt: String, maxTokens: Int, sampler: LlamaCppVLM.GGUFSamplerSpec,
                      onToken: @escaping (String) -> Void) throws -> LlamaCppVLM.GGUFTextResult {
        throw LlamaCppError.unsupportedModel(MiniCPMV47Catalog.streaming35BRequirement)
    }
}

func colorImage(red: CGFloat, blue: CGFloat) -> UIImage {
    let context = CGContext(data: nil, width: 224, height: 224,
        bitsPerComponent: 8, bytesPerRow: 224 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 224, height: 224))
    return UIImage(cgImage: context.makeImage())
}
SWIFT
cat > "$minicpm_work/main.swift" <<'SWIFT'
import Foundation

func run() throws {
llama_log_set({ _, _, _ in }, nil)
mtmd_log_set({ _, _, _ in }, nil)
ggml_log_set({ _, _, _ in }, nil)
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.contains("--guard-only") {
    let alias = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
    defer { try? FileManager.default.removeItem(at: alias) }
    let source = try FileHandle(forReadingFrom: directory.appendingPathComponent(MiniCPMV47Catalog.thirtyFiveB.modelFilename))
    defer { try? source.close() }
    try source.read(upToCount: 65_536)!.write(to: alias)
    do {
        _ = try LlamaCppVLM(llmPath: alias.path)
        preconditionFailure("Renamed 35B GGUF reached ordinary native construction")
    } catch let error as LlamaCppError {
        precondition(error == .unsupportedModel(MiniCPMV47Catalog.streaming35BRequirement))
    }
    print("PASS: actual 35B metadata refused through a renamed GGUF before native construction")
    return
}
let model = MiniCPMV47Catalog.oneB
var bridge: LlamaCppVLM? = try LlamaCppVLM(
    llmPath: directory.appendingPathComponent(model.modelFilename).path,
    mmprojPath: directory.appendingPathComponent(model.projectorFilename).path,
    contextSize: 4_096
)
func checkColor(_ expected: String, red: CGFloat, blue: CGFloat) throws {
    let active = bridge!
    var output = ""
    var completed = false
    try active.describe(image: colorImage(red: red, blue: blue),
        prompt: "Name the dominant color of this image in one word.",
        maxTokens: 64, onToken: { output += $0 }, onComplete: { _ in completed = true })
    precondition(completed && output.lowercased().contains(expected), "Image inference failed")
    precondition(!output.contains("<think>"), "Lens leaked a reasoning trace")
}
try checkColor("red", red: 1, blue: 0)
try checkColor("blue", red: 0, blue: 1)
var cancellationRequested = false
do {
    try bridge!.describe(image: colorImage(red: 1, blue: 0),
        prompt: "Describe this image in detail.", maxTokens: 128,
        onToken: { _ in cancellationRequested = true; bridge?.cancelCurrent() },
        onComplete: { _ in })
} catch let error as LlamaCppError {
    if error != .cancelled { throw error }
}
precondition(cancellationRequested, "Cancellation path did not generate a token")
try checkColor("blue", red: 0, blue: 1)
bridge = nil // exercise the production native-handle destructor
bridge = try LlamaCppVLM(
    llmPath: directory.appendingPathComponent(model.modelFilename).path,
    mmprojPath: directory.appendingPathComponent(model.projectorFilename).path,
    contextSize: 4_096
)
try checkColor("red", red: 1, blue: 0)
bridge = nil
do {
    _ = try LlamaCppVLM(llmPath: "/missing/MiniCPM-V-4_7-35B-A3B-mix_q3gud_im-les.gguf")
    preconditionFailure("35B model bypassed streaming validation")
} catch let error as LlamaCppError {
    precondition(error == .unsupportedModel(MiniCPMV47Catalog.streaming35BRequirement))
}
print("PASS: four image turns, cancellation/retry, unload/reload, 35B refusal")
}
do {
    try run()
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
SWIFT
swiftc -swift-version 5 \
    -module-cache-path "$minicpm_work/module-cache" \
    -I "$minicpm_framework/llama.framework/Headers" \
    -F "$minicpm_framework" -framework llama \
    -Xlinker -rpath -Xlinker "$minicpm_framework" \
    -import-objc-header "$minicpm_work/Bridge.h" \
    "$minicpm_work/Fixtures.swift" "$minicpm_work/GGUFPrefixCache.swift" \
    "$minicpm_root/IOSLocalLLM/Models/MiniCPMV47Catalog.swift" \
    "$minicpm_work/LlamaCppBridge.swift" "$minicpm_work/main.swift" \
    -o "$minicpm_work/checks"
"$minicpm_work/checks" "$minicpm_models" "${2:-}"
