#!/usr/bin/env bash
# Exercise the isolated 35B engine with a prepared, locally verified pack.
# Uses synthetic images and never prints model output.
set -euo pipefail
minicpm_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
minicpm_models="${1:?Usage: test_minicpm_v47_35b_live.sh /path/to/prepared/35B}"
minicpm_framework="${MINICPM_VALIDATION_FRAMEWORK_DIR:-$minicpm_root/build/MiniCPMNative/ODMiniCPM.xcframework/macos-arm64}"
minicpm_shared="$minicpm_root/build/ClassifierNative/llama.xcframework/macos-arm64_x86_64"
minicpm_work="$(mktemp -d)"
trap 'rm -rf "$minicpm_work"' EXIT
printf '#include "llama.h"\n' > "$minicpm_work/Bridge.h"
cat > "$minicpm_work/main.swift" <<'SWIFT'
import Foundation
import Dispatch
import ODMiniCPM
final class Capture {
    var bytes = Data()
    var cancelAfterFirst = false
    var engine: OpaquePointer?
    var stages: [Int] = []
    var emittedPieces = 0
    var cancelAfterPieces = 0
}
func run() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    try MiniCPMV47Artifacts.validate(in: root)
    llama_log_set({ _, _, _ in }, nil)
    llama_backend_init()
    precondition(llama_context_default_params().n_ctx > 0)
    func load(textOnly: Bool = false, cache: UInt32 = 16, context: UInt32 = 4096) throws -> OpaquePointer {
        var error = [CChar](repeating: 0, count: 256)
        let created: OpaquePointer?
        if textOnly {
            created = od_mini47_create(root.appendingPathComponent(MiniCPMV47Artifacts.modelName).path, nil,
                root.appendingPathComponent("experts/manifest.json").path, context, cache, nil, nil, &error, error.count)
        } else {
            created = od_mini47_create(root.appendingPathComponent(MiniCPMV47Artifacts.modelName).path,
                root.appendingPathComponent(MiniCPMV47Artifacts.projectorName).path,
                root.appendingPathComponent("experts/manifest.json").path, context, cache, nil, nil, &error, error.count)
        }
        guard let engine = created
        else { throw NSError(domain: "MiniCPMTest", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: error)]) }
        precondition(od_mini47_routed_experts(engine) == 8)
        precondition(llama_context_default_params().n_ctx > 0)
        var metrics = od_mini47_metrics()
        precondition(od_mini47_get_metrics(engine, &metrics))
        precondition(metrics.has_vision == !textOnly && metrics.cache_slots == cache)
        precondition(metrics.shared_bank_slots == (textOnly ? 256 : 40))
        precondition(metrics.microbatch == (textOnly ? 128 : 4))
        return engine
    }
    func describe(_ engine: OpaquePointer, red: Bool, cancel: Bool = false) throws {
        var rgb = [UInt8](repeating: 0, count: 224 * 224 * 3)
        for pixel in 0..<(224 * 224) { rgb[pixel * 3 + (red ? 0 : 2)] = 255 }
        let capture = Capture(); capture.engine = engine; capture.cancelAfterFirst = cancel
        let stagesOnly = CommandLine.arguments.contains("--stages-only")
        let prompt = MiniCPMV47Catalog.instructVisionPrompt("Name the dominant color of this image in one word.", marker: "<__media__>")
        var speed: Double = 0
        let status = rgb.withUnsafeBufferPointer { pixels in
            od_mini47_describe(engine, pixels.baseAddress, 224, 224, prompt, stagesOnly ? 1 : 64, { bytes, count, context in
                guard let context else { return }
                let capture = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
                guard let bytes else { capture.stages.append(count); return }
                capture.bytes.append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: count)
                if capture.cancelAfterFirst { od_mini47_cancel(capture.engine) }
            }, Unmanaged.passUnretained(capture).toOpaque(), &speed)
        }
        precondition(capture.stages == [1, 2, 3])
        if cancel { precondition(status == 1 && !capture.bytes.isEmpty); return }
        guard status == 0 else { throw NSError(domain: "MiniCPMTest", code: Int(status)) }
        if stagesOnly { precondition(capture.stages == [1, 2, 3]); print("PASS: real image encoding, prefill and decode stage order"); return }
        let text = String(decoding: capture.bytes, as: UTF8.self).lowercased()
        precondition(text.contains(red ? "red" : "blue"), "Image inference did not identify its input")
        precondition(!text.contains("<think>"), "Instruct mode emitted reasoning")
        print("PASS: image input matched, decode completed, top-eight routing preserved")
    }
    func text(_ engine: OpaquePointer, limit: UInt32 = 64, cancel: Bool = false) throws {
        let capture = Capture(); capture.engine = engine; capture.cancelAfterFirst = cancel
        let prompt = "<|im_start|>system\nAnswer concisely.<|im_end|>\n<|im_start|>user\nWhat is 2 plus 2? Answer with one digit.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        var speed: Double = 0, input: UInt32 = 0, output: UInt32 = 0
        var truncated = false
        let status = od_mini47_text(engine, prompt, limit, 0, 1, 1, 1, 0, { bytes, count, context in
            guard let bytes, let context else { return }
            let capture = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
            capture.bytes.append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: count)
            if capture.cancelAfterFirst { od_mini47_cancel(capture.engine) }
        }, Unmanaged.passUnretained(capture).toOpaque(), &speed, &input, &output, &truncated)
        if cancel { precondition(status == 1 && !capture.bytes.isEmpty); return }
        precondition(status == 0 && input > 0 && output > 0 && output <= limit)
        let result = String(decoding: capture.bytes, as: UTF8.self)
        precondition(result.trimmingCharacters(in: .whitespacesAndNewlines) == "4")
        if limit == 1 { precondition(truncated && output == 1) }
        precondition(od_mini47_routed_experts(engine) == 8)
        print("PASS: text arithmetic, instruct template, sampling and output metrics")
    }
    func adaptiveText(_ engine: OpaquePointer, filler: Int, ceiling: UInt32, expectedBatch: UInt32,
                      cancel: Bool = false) throws {
        let capture = Capture(); capture.engine = engine; capture.cancelAfterFirst = cancel
        let prompt = "<|im_start|>user\nReference records: " + String(repeating: "alpha ", count: filler)
            + " Ignore the records. What is 2 plus 2? Answer with one digit.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        var speed: Double = 0, input: UInt32 = 0, output: UInt32 = 0
        var truncated = false
        let status = od_mini47_text_optimized(engine, prompt, 32, ceiling, 0, 1, 1, 1, 0, { bytes, count, context in
            guard let bytes, let context else { return }
            let capture = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
            capture.bytes.append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: count)
            if capture.cancelAfterFirst { od_mini47_cancel(capture.engine) }
        }, Unmanaged.passUnretained(capture).toOpaque(), &speed, &input, &output, &truncated)
        if cancel { precondition(status == 1 && !capture.bytes.isEmpty) }
        else {
            precondition(status == 0 && input > 0 && output > 0)
            precondition(String(decoding: capture.bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "4")
        }
        var metrics = od_mini47_metrics()
        precondition(od_mini47_get_metrics(engine, &metrics) && metrics.microbatch == expectedBatch)
        precondition(metrics.decode_microbatch == 128)
        precondition(metrics.routed_experts == 8 && !metrics.has_vision)
        precondition(metrics.has_expert_counters && (cancel || metrics.expert_process_ms > 0))
        precondition(metrics.prompt_eval_api_ms.isFinite && metrics.context_switch_ms.isFinite)
        print("PASS: adaptive text batch=\(metrics.microbatch), input=\(input), cancel=\(cancel)")
    }
    func cancelPrefill(_ engine: OpaquePointer) throws {
        let capture = Capture()
        let prompt = "<|im_start|>user\n" + String(repeating: "alpha ", count: 800)
            + "What is 2 plus 2?<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 0.1)
            var metrics = od_mini47_metrics()
            precondition(!od_mini47_get_metrics(engine, &metrics))
            od_mini47_cancel(engine)
            finished.signal()
        }
        var rate: Double = 0, input: UInt32 = 0, output: UInt32 = 0
        var limit = false
        let emit: od_mini47_token = { bytes, count, context in
            guard let bytes, let context else { return }
            Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().bytes
                .append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: count)
        }
        let opaque = Unmanaged.passUnretained(capture).toOpaque()
        let status: Int32
        if CommandLine.arguments.contains("--adaptive") {
            status = od_mini47_text_optimized(engine, prompt, 64, 512, 0, 1, 1, 1, 0,
                emit, opaque, &rate, &input, &output, &limit)
        } else {
            status = od_mini47_text(engine, prompt, 64, 0, 1, 1, 1, 0,
                emit, opaque, &rate, &input, &output, &limit)
        }
        finished.wait()
        precondition(status == 1 && capture.bytes.isEmpty)
        try text(engine)
        print("PASS: prompt preparation cancellation, nonblocking metrics and retry")
    }
    func longReply(_ engine: OpaquePointer) throws {
        var prefix = "<|im_start|>system\nYou write complete, correct standalone code.<|im_end|>\n<|im_start|>user\nCreate a complete standalone HTML page. Include an animated gradient background, a styled card with a title, 12 numbered buttons, and JavaScript that displays which button was clicked. Include the CSS, the HTML body and the script. Return only the full document without markdown fences.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let prefixCache = CommandLine.arguments.contains("--prefix-cache")
        if prefixCache {
            prefix = prefix.replacingOccurrences(of: "Create a complete", with:
                "Reference records: " + String(repeating: "alpha ", count: 1_100)
                + "\nIgnore the reference records. Create a complete")
        }
        func generate(_ prompt: String, limit: UInt32, cancelAfter: Int = 0) -> (Int32, Capture, UInt32, UInt32, Bool) {
            let capture = Capture(); capture.engine = engine; capture.cancelAfterPieces = cancelAfter
            var rate: Double = 0, input: UInt32 = 0, output: UInt32 = 0
            var truncated = false
            let emit: od_mini47_token = { bytes, length, context in
                guard let bytes, let context else { return }
                let c = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
                c.bytes.append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: length)
                c.emittedPieces += 1
                if c.cancelAfterPieces > 0 && c.emittedPieces >= c.cancelAfterPieces { od_mini47_cancel(c.engine) }
            }
            let opaque = Unmanaged.passUnretained(capture).toOpaque()
            let status: Int32
            if prefixCache {
                status = od_mini47_text_cached(engine, prompt, limit, 1024, true, 0, 1, 1, 1, 0,
                    emit, opaque, &rate, &input, &output, &truncated)
            } else if CommandLine.arguments.contains("--adaptive") {
                let ceiling: UInt32 = CommandLine.arguments.contains("--large-prompt") ? 1024 : 512
                status = od_mini47_text_optimized(engine, prompt, limit, ceiling, 0, 1, 1, 1, 0,
                    emit, opaque, &rate, &input, &output, &truncated)
            } else {
                status = od_mini47_text(engine, prompt, limit, 0, 1, 1, 1, 0,
                    emit, opaque, &rate, &input, &output, &truncated)
            }
            if status == 0 {
                var metrics = od_mini47_metrics()
                precondition(od_mini47_get_metrics(engine, &metrics))
                precondition(metrics.has_expert_counters && metrics.expert_process_ms > 0)
                precondition(metrics.decode_api_ms + metrics.sampling_ms + metrics.callback_ms <= metrics.decode_ms + 5)
                if prefixCache {
                    precondition(metrics.prefix_state_bytes > 0
                        && metrics.prefix_state_bytes <= UInt64(MiniCPM35BTextProfile.maximumPrefixStateBytes))
                    precondition(metrics.prefix_checkpoint_tokens >= 1024)
                }
            }
            return (status, capture, input, output, truncated)
        }
        let cancelled = generate(prefix, limit: 2048, cancelAfter: 300)
        precondition(cancelled.0 == 1 && cancelled.1.emittedPieces == 300)
        print("PASS: cancellation after 300 streamed tokens; no former 256-token stop")
        let first = generate(prefix, limit: 384)
        precondition(first.0 == 0 && first.3 == 384 && first.4)
        let continuation = generate(prefix + String(decoding: first.1.bytes, as: UTF8.self), limit: 2048)
        precondition(continuation.0 == 0 && !continuation.4)
        let completed = String(decoding: first.1.bytes + continuation.1.bytes, as: UTF8.self).lowercased()
        precondition(completed.contains("</html>") && completed.contains("<script") && !completed.contains("<think>"))
        precondition(Int(continuation.2) + Int(continuation.3) < 4096)
        if prefixCache {
            var metrics = od_mini47_metrics()
            precondition(od_mini47_get_metrics(engine, &metrics) && metrics.prefix_reused_tokens >= 1024)
        }
        print("PASS: HTML exceeded 256 tokens and completed after an open-turn continuation; output=\(first.3 + continuation.3)")
        let full = generate(prefix, limit: 2048)
        precondition(full.0 == 0 && full.3 > 256 && !full.4)
        precondition(String(decoding: full.1.bytes, as: UTF8.self).lowercased().contains("</html>"))
        if prefixCache { precondition(first.1.bytes + continuation.1.bytes == full.1.bytes) }
        print("PASS: complete long HTML document without the old cutoff; output=\(full.3)")
    }
    if CommandLine.arguments.contains("--long-replies") {
        let caches: [UInt32] = CommandLine.arguments.contains("--cache48") ? [48]
            : (CommandLine.arguments.contains("--adaptive") ? [32, 48] : [16, 24])
        for cache in caches {
            let engine = try load(textOnly: true, cache: cache)
            if CommandLine.arguments.contains("--adaptive") {
                try adaptiveText(engine, filler: 0, ceiling: 512, expectedBatch: 128)
                try adaptiveText(engine, filler: 180, ceiling: 512, expectedBatch: 256)
                try adaptiveText(engine, filler: 800, ceiling: 512, expectedBatch: 512, cancel: true)
                try adaptiveText(engine, filler: 800, ceiling: 256, expectedBatch: 256)
                try adaptiveText(engine, filler: 800, ceiling: 1024, expectedBatch: 1024)
                try adaptiveText(engine, filler: 0, ceiling: 512, expectedBatch: 128)
                try cancelPrefill(engine)
            }
            try longReply(engine)
            try text(engine, cancel: true)
            try text(engine)
            od_mini47_free(engine)
        }
        let small = try load(textOnly: true, cache: 16, context: 512)
        defer { od_mini47_free(small) }
        let prompt = "<|im_start|>user\nReference data: " + String(repeating: "alpha ", count: 350)
            + " Ignore the data. List the integers from 1 through 1000.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        var rate: Double = 0, input: UInt32 = 0, output: UInt32 = 0
        var hitLimit = false
        let status = od_mini47_text(small, prompt, 2048, 0, 1, 1, 1, 0, nil, nil, &rate, &input, &output, &hitLimit)
        precondition(status == 0 && input > 300 && output == 511 - input && hitLimit)
        print("PASS: exact remaining-context clamp in a 512-token runtime; input=\(input) output=\(output)")
        print("PASS: long replies and continuation with all selected text cache profiles")
        return
    }
    if CommandLine.arguments.contains("--text-only") {
        for cache: UInt32 in [16, 24] {
            let engine = try load(textOnly: true, cache: cache)
            try text(engine)
            try text(engine, limit: 1)
            try text(engine, cancel: true)
            try text(engine)
            try cancelPrefill(engine)
            let overlong = String(repeating: "alpha ", count: 5_000)
            var rate: Double = 0, input: UInt32 = 0, output: UInt32 = 0
            var limit = false
            precondition(od_mini47_text(engine, overlong, 64, 0, 1, 1, 1, 0, nil, nil,
                &rate, &input, &output, &limit) == -5)
            precondition(input > 4_000)
            try text(engine)
            od_mini47_free(engine)
        }
        print("PASS: text-only 16/24 caches, cancellation/retry, context refusal and reload")
        return
    }
    if CommandLine.arguments.contains("--stages-only") {
        let engine = try load(); defer { od_mini47_free(engine) }
        try describe(engine, red: true)
        try text(engine)
        return
    }
    do {
        let engine = try load()
        defer { od_mini47_free(engine) }
        try describe(engine, red: true)
        try text(engine)
        try text(engine, limit: 1)
        try text(engine, cancel: true)
        try text(engine)
        try describe(engine, red: false)
        try describe(engine, red: true, cancel: true)
        try describe(engine, red: false)
    }
    do {
        let reloaded = try load()
        defer { od_mini47_free(reloaded) }
        try describe(reloaded, red: true)
        try text(reloaded)
    }
    print("PASS: repeated 35B images, cancellation/retry, unload/reload, shared runtime coexistence")
}
do { try run() }
catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
SWIFT
swiftc -swift-version 5 -module-cache-path "$minicpm_work/module-cache" \
    -F "$minicpm_framework" -framework ODMiniCPM \
    -Xlinker -rpath -Xlinker "$minicpm_framework" \
    -I "$minicpm_shared/llama.framework/Headers" \
    -F "$minicpm_shared" -framework llama \
    -Xlinker -rpath -Xlinker "$minicpm_shared" \
    -import-objc-header "$minicpm_work/Bridge.h" \
    "$minicpm_root/IOSLocalLLM/Models/MiniCPMV47Catalog.swift" \
    "$minicpm_root/IOSLocalLLM/Services/Runtime/MiniCPMV47/MiniCPMV47Artifacts.swift" \
    "$minicpm_root/IOSLocalLLM/Services/Runtime/MiniCPMV47/MiniCPM35BTextProfile.swift" \
    "$minicpm_work/main.swift" -o "$minicpm_work/checks"
"$minicpm_work/checks" "$minicpm_models" "${@:2}"
