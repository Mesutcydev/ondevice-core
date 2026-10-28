import Foundation
import UIKit
#if canImport(ODMiniCPM)
import ODMiniCPM
#endif

/// One owner for either native vision engine. The existing llama.cpp bridge
/// remains the implementation for every model except the exact MiniCPM 35B
/// family; lifecycle and cancellation still belong to LlamaCppVLMService.
enum LlamaCppVisionBackend: @unchecked Sendable {
    case standard(LlamaCppVLM)
    case miniCPM35B(MiniCPMV47StreamingVLM)

    init(repoID: String, directory: URL, llmPath: String, projectorPath: String, contextSize: UInt32) throws {
        if MiniCPMV47Catalog.is35B(repoID) || MiniCPMV47Catalog.is35B(llmPath) {
            self = .miniCPM35B(try MiniCPMV47StreamingVLM(directory: directory, contextSize: contextSize))
        } else {
            self = .standard(try LlamaCppVLM(llmPath: llmPath, mmprojPath: projectorPath, contextSize: contextSize))
        }
    }
    func cancelCurrent() {
        switch self { case .standard(let model): model.cancelCurrent()
        case .miniCPM35B(let model): model.cancelCurrent() }
    }
    func describe(image: UIImage, prompt: String, maxTokens: Int,
                  onToken: @escaping (String) -> Void, onComplete: @escaping (Double) -> Void,
                  onStage: @escaping (VisionInferenceStage) -> Void = { _ in }) throws {
        switch self {
        case .standard(let model): try model.describe(image: image, prompt: prompt, maxTokens: maxTokens, onToken: onToken, onComplete: onComplete)
        case .miniCPM35B(let model): try model.describe(image: image, prompt: prompt, maxTokens: maxTokens, onToken: onToken, onComplete: onComplete, onStage: onStage)
        }
    }
}

final class MiniCPMV47StreamingVLM {
    let cacheSlots: UInt32
    #if canImport(ODMiniCPM)
    private let engine: OpaquePointer

    init(directory: URL, contextSize: UInt32, textOnly: Bool = false, cacheSlots: UInt32 = 16) throws {
        self.cacheSlots = cacheSlots
        try MiniCPMV47Artifacts.validate(in: directory)
        let model = directory.appendingPathComponent(MiniCPMV47Artifacts.modelName).path
        let projector = directory.appendingPathComponent(MiniCPMV47Artifacts.projectorName).path
        let manifest = directory.appendingPathComponent("experts/manifest.json").path
        var error = [CChar](repeating: 0, count: 256)
        let loaded: OpaquePointer?
        if textOnly {
            loaded = od_mini47_create(model, nil, manifest, contextSize, cacheSlots,
                                     { _ in Task.isCancelled }, nil, &error, error.count)
        } else {
            loaded = od_mini47_create(model, projector, manifest, contextSize, cacheSlots,
                                     { _ in Task.isCancelled }, nil, &error, error.count)
        }
        guard let loaded else { throw LlamaCppError.unsupportedModel(String(cString: error)) }
        guard od_mini47_routed_experts(loaded) == 8 else {
            od_mini47_free(loaded)
            throw LlamaCppError.unsupportedModel("MiniCPM expert routing could not be verified.")
        }
        engine = loaded
    }
    deinit { od_mini47_free(engine) }
    func cancelCurrent() { od_mini47_cancel(engine) }

    private final class Stream {
        var pending = Data()
        let onToken: (String) -> Void
        let onStage: (VisionInferenceStage) -> Void
        init(_ onToken: @escaping (String) -> Void, onStage: @escaping (VisionInferenceStage) -> Void = { _ in }) {
            self.onToken = onToken; self.onStage = onStage
        }
        func accept(_ bytes: UnsafePointer<CChar>, count: Int) {
            pending.append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: count)
            if let value = String(data: pending, encoding: .utf8) { pending.removeAll(keepingCapacity: true); onToken(value) }
        }
    }
    func generateText(prompt: String, maxTokens: Int, sampler: LlamaCppVLM.GGUFSamplerSpec,
                      maximumMicrobatch: UInt32 = 128,
                      allowPrefixCache: Bool = false,
                      onToken: @escaping (String) -> Void) throws -> LlamaCppVLM.GGUFTextResult {
        guard !Task.isCancelled else { throw LlamaCppError.cancelled }
        let stream = Stream(onToken)
        var speed: Double = 0, promptTokens: UInt32 = 0, outputTokens: UInt32 = 0
        var hitLimit = false
        let emit: od_mini47_token = { bytes, count, context in
            guard let bytes, let context else { return }
            Unmanaged<Stream>.fromOpaque(context).takeUnretainedValue().accept(bytes, count: count)
        }
        let opaque = Unmanaged.passUnretained(stream).toOpaque()
        let budget = UInt32(max(1, min(MiniCPM35BTextProfile.maximumRequestedOutputTokens, maxTokens)))
        let status: Int32
        if allowPrefixCache {
            status = od_mini47_text_cached(engine, prompt, budget, maximumMicrobatch, true,
                min(2, max(0, sampler.temperature)), min(1, max(0.01, sampler.topP)), max(0, sampler.topK),
                min(2, max(0.01, sampler.repetitionPenalty)), sampler.seed ?? UInt32.max,
                emit, opaque, &speed, &promptTokens, &outputTokens, &hitLimit)
        } else if maximumMicrobatch > 128 {
            status = od_mini47_text_optimized(engine, prompt, budget, maximumMicrobatch,
                min(2, max(0, sampler.temperature)), min(1, max(0.01, sampler.topP)), max(0, sampler.topK),
                min(2, max(0.01, sampler.repetitionPenalty)), sampler.seed ?? UInt32.max,
                emit, opaque, &speed, &promptTokens, &outputTokens, &hitLimit)
        } else {
            status = od_mini47_text(engine, prompt, budget,
                min(2, max(0, sampler.temperature)), min(1, max(0.01, sampler.topP)), max(0, sampler.topK),
                min(2, max(0.01, sampler.repetitionPenalty)), sampler.seed ?? UInt32.max,
                emit, opaque, &speed, &promptTokens, &outputTokens, &hitLimit)
        }
        if !stream.pending.isEmpty { onToken(String(decoding: stream.pending, as: UTF8.self)) }
        switch status {
        case 0:
            var metrics = od_mini47_metrics()
            if od_mini47_get_metrics(engine, &metrics) {
                Diagnostics.shared.breadcrumb(String(format:
                    "MiniCPM text timings · load=%.0fms prefill=%.0fms firstToken=%.0fms decode=%.0fms input=%u output=%u bank=%u batch=%u cache=%u vision=%d decodeBatch=%u",
                    metrics.load_ms, metrics.prefill_ms, metrics.first_token_ms, metrics.decode_ms,
                    metrics.prompt_tokens, metrics.output_tokens, metrics.shared_bank_slots,
                    metrics.microbatch, metrics.cache_slots, metrics.has_vision ? 1 : 0,
                    metrics.decode_microbatch), category: "assistant")
                Diagnostics.shared.breadcrumb(String(format:
                    "MiniCPM call timings · promptEvalAPI=%.0fms contextSwitch=%.0fms prefillSample=%.0fms decodeAPI=%.0fms sample=%.0fms emit=%.0fms park=%.0fms",
                    metrics.prompt_eval_api_ms, metrics.context_switch_ms, metrics.prefill_sampling_ms,
                    metrics.decode_api_ms, metrics.sampling_ms, metrics.callback_ms, metrics.park_ms), category: "assistant")
                Diagnostics.shared.breadcrumb(String(format:
                    "MiniCPM prefix cache · reused=%u checkpoint=%u stateBytes=%llu allowed=%d",
                    metrics.prefix_reused_tokens, metrics.prefix_checkpoint_tokens,
                    metrics.prefix_state_bytes, allowPrefixCache ? 1 : 0), category: "assistant")
                if metrics.has_expert_counters {
                    Diagnostics.shared.breadcrumb(String(format:
                        "MiniCPM decode expert counters · process=%.0fms readIDs=%.0fms install=%.0fms writeIDs=%.0fms misses=%llu bytes=%llu",
                        metrics.expert_process_ms, metrics.expert_readids_ms, metrics.expert_install_ms,
                        metrics.expert_writeids_ms, metrics.expert_misses, metrics.expert_read_bytes), category: "assistant")
                }
            }
            return .init(tokensPerSecond: speed, hitTokenLimit: hitLimit,
                             promptTokens: Int(promptTokens), outputTokens: Int(outputTokens))
        case 1: throw LlamaCppError.cancelled
        case -2: throw LlamaCppError.generationInProgress
        case -5: throw LlamaCppError.promptTooLong(Int(promptTokens))
        case -8: throw LlamaCppError.noOutput
        default: throw LlamaCppError.decodeFailed(status)
        }
    }
    func describe(image: UIImage, prompt: String, maxTokens: Int,
                  onToken: @escaping (String) -> Void, onComplete: @escaping (Double) -> Void,
                  onStage: @escaping (VisionInferenceStage) -> Void = { _ in }) throws {
        guard !Task.isCancelled else { throw LlamaCppError.cancelled }
        // Flatten image orientation and bound host pixel buffers before native
        // encoding. 2048px preserves document detail without an unbounded copy.
        let scale = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let cg = rendered.cgImage else { throw LlamaCppError.bitmapInitFailed }
        let width = cg.width, height = cg.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBufferPointer { pixels -> Bool in
            guard let context = CGContext(data: pixels.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw LlamaCppError.bitmapInitFailed }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]; rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]; rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        let stream = Stream(onToken, onStage: onStage)
        let opaque = Unmanaged.passUnretained(stream).toOpaque()
        let fullPrompt = MiniCPMV47Catalog.instructVisionPrompt(prompt, marker: "<__media__>")
        var speed: Double = 0
        let status = rgb.withUnsafeBufferPointer { pixels in
            od_mini47_describe(engine, pixels.baseAddress, UInt32(width), UInt32(height), fullPrompt,
                              UInt32(max(1, min(256, maxTokens))), { bytes, count, context in
                guard let context else { return }
                let stream = Unmanaged<Stream>.fromOpaque(context).takeUnretainedValue()
                if let bytes { stream.accept(bytes, count: count) }
                else { stream.onStage(count == 1 ? .readingImage : count == 2 ? .preparingAnswer : .writingAnswer) }
            }, opaque, &speed)
        }
        if !stream.pending.isEmpty { onToken(String(decoding: stream.pending, as: UTF8.self)) }
        switch status {
        case 0: onComplete(speed)
        case 1: throw LlamaCppError.cancelled
        case -2: throw LlamaCppError.generationInProgress
        case -5: throw LlamaCppError.promptTooLong(4096)
        case -8: throw LlamaCppError.noOutput
        default: throw LlamaCppError.decodeFailed(status)
        }
    }
    #else
    init(directory: URL, contextSize: UInt32, textOnly: Bool = false, cacheSlots: UInt32 = 16) throws { throw LlamaCppError.unsupportedModel(MiniCPMV47Catalog.streaming35BRequirement) }
    func cancelCurrent() {}
    func generateText(prompt: String, maxTokens: Int, sampler: LlamaCppVLM.GGUFSamplerSpec,
                      maximumMicrobatch: UInt32 = 128,
                      allowPrefixCache: Bool = false,
                      onToken: @escaping (String) -> Void) throws -> LlamaCppVLM.GGUFTextResult {
        throw LlamaCppError.unsupportedModel(MiniCPMV47Catalog.streaming35BRequirement)
    }
    func describe(image: UIImage, prompt: String, maxTokens: Int,
                  onToken: @escaping (String) -> Void, onComplete: @escaping (Double) -> Void,
                  onStage: @escaping (VisionInferenceStage) -> Void = { _ in }) throws {
        throw LlamaCppError.unsupportedModel(MiniCPMV47Catalog.streaming35BRequirement)
    }
    #endif
}
