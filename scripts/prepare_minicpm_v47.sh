#!/usr/bin/env bash
# Prepare a pinned official GGUF in place using the production iPhone repacker.
# No network access; the source download is retained until atomic activation.
set -euo pipefail
minicpm_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
minicpm_models="${1:?Usage: prepare_minicpm_v47.sh /path/to/official/35B/download [--pause-after-layer]}"
minicpm_work="$(mktemp -d)"
trap 'rm -rf "$minicpm_work"' EXIT
cat > "$minicpm_work/Run.swift" <<'SWIFT'
import Foundation
final class Gate: @unchecked Sendable {
    let lock = NSLock()
    var paused = false
    func pause() { lock.lock(); paused = true; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if paused { throw CancellationError() } }
}
@main struct Prepare {
    static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let pause = CommandLine.arguments.contains("--pause-after-layer")
        let gate = Gate()
        do {
            try await MiniCPMV47Artifacts.prepare(in: root, sourceRevision: MiniCPMV47Catalog.thirtyFiveBRevision,
                checkpoint: { try Task.checkCancellation(); try gate.check() },
                report: { progress in
                    if progress.step.hasSuffix("1 of 40") && pause { gate.pause() }
                    if progress.step.hasSuffix("0 of 40") || progress.fraction == 0 || progress.fraction == 1 {
                        print(progress.step)
                    }
                })
            let receipt = try MiniCPMV47Artifacts.validate(in: root)
            print("PASS: prepared \(receipt.files.count) verified artifacts with top-eight routing")
        } catch is CancellationError {
            guard pause else { throw CancellationError() }
            precondition(!MiniCPMV47Artifacts.isPrepared(in: root))
            precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent(MiniCPMV47Artifacts.modelName).path))
            print("PASS: preparation paused; original source retained for resume")
        }
    }
}
SWIFT
swiftc -swift-version 5 -module-cache-path "$minicpm_work/module-cache" \
    "$minicpm_root/IOSLocalLLM/Models/MiniCPMV47Catalog.swift" \
    "$minicpm_root/IOSLocalLLM/Services/Runtime/MiniCPMV47/MiniCPMV47Artifacts.swift" \
    "$minicpm_work/Run.swift" -o "$minicpm_work/prepare"
"$minicpm_work/prepare" "$minicpm_models" "${2:-}"
