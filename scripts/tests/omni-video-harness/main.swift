// Runs the app's LFM3-Omni video path (OmniVideoInput, OmniVideoFeed and the
// LFM3 prompt) against the real model on a Mac. Built and driven by
// scripts/test_omni_video_on_mac.sh; not part of the app target.
import Foundation
import AVFoundation

@main
struct OmniVideoHarness {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            print("usage: harness <model.gguf> <mmproj.gguf> <video> [question] [max frames]")
            exit(64)
        }
        let question = args.count > 4 ? args[4] : "Describe what happens in this video, including what you can hear."
        let frameCap = args.count > 5 ? Int(args[5]) ?? 64 : 64

        llama_backend_init()
        // OMNI_HARNESS_LOG=1 prints mtmd's own log (same lines as llama-mtmd-cli -v).
        if ProcessInfo.processInfo.environment["OMNI_HARNESS_LOG"] == "1" {
            mtmd_log_set({ _, text, _ in if let text { fputs(String(cString: text), stderr) } }, nil)
        } else {
            mtmd_log_set({ _, _, _ in }, nil)
        }
        guard let model = llama_model_load_from_file(args[1], llama_model_default_params()) else { fail("model") }
        var params = llama_context_default_params()
        params.n_ctx = 16_384      // LlamaCppVLMExecutionProfile for Omni
        params.n_batch = 512
        params.n_ubatch = 512
        guard let ctx = llama_init_from_model(model, params) else { fail("context") }
        guard let mc = mtmd_init_from_file(args[2], model, mtmd_context_params_default()) else { fail("projector") }

        let url = URL(fileURLWithPath: args[3])
        // OMNI_HARNESS_SOURCE=live replays the clip the way a Lens clip arrives:
        // frames already sampled at 2 fps plus a separate audio file.
        let source: OmniVideoSource
        if ProcessInfo.processInfo.environment["OMNI_HARNESS_SOURCE"] == "live" {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            let length = try await OmniVideoClip.probe(url).duration
            var frames: [CGImage] = []
            for step in 0..<Int(length * 2) {
                frames.append(try await generator.image(at: CMTime(seconds: Double(step) / 2, preferredTimescale: 600)).image)
            }
            source = .live(frames: frames, fps: 2, audio: url)
        } else {
            source = .file(url)
        }
        let probe = try await source.probe()
        let recommended = mtmd_get_video_config(mc, Int32(probe.width), Int32(probe.height),
                                                Int32(probe.sourceFrames), Float(probe.fps))
        guard recommended.tmpl == MTMD_VIDEO_TEMPLATE_LFM3_OMNI else { fail("not an Omni projector") }
        let frames = min(Int(recommended.n_frames), frameCap)
        let sized = frames == Int(recommended.n_frames) ? recommended
            : mtmd_get_video_config(mc, Int32(probe.width), Int32(probe.height),
                                    Int32((Double(frames) / 2 * probe.fps).rounded(.up)), Float(probe.fps))
        let rate = Int(mtmd_get_audio_sample_rate(mc))
        let clip = try await source.clip(probe: probe, frameCount: frames,
                                         width: Int(sized.frame_width), height: Int(sized.frame_height),
                                         sampleRate: rate)
        print("probe: \(probe.width)x\(probe.height) \(probe.fps) fps \(probe.sourceFrames) frames \(probe.duration) s")
        print("clip: \(clip.frames.count) frames at \(clip.width)x\(clip.height), \(clip.soundtrack.count) samples at \(rate) Hz, \(clip.items.count) items")

        let feed = OmniVideoFeed(clip)
        guard let video = feed.makeBitmap(mc) else { fail("lazy bitmap") }
        let prompt = LFM3Catalog.visionPrompt(question, marker: String(cString: mtmd_get_marker(mc)))
        let chunks = mtmd_input_chunks_init()
        let status: Int32 = withExtendedLifetime(feed) {
            prompt.withCString { text in
                var input = mtmd_input_text()
                input.text = text
                input.text_len = strlen(text)
                input.add_special = true
                input.parse_special = true
                var media: [OpaquePointer?] = [video]
                return media.withUnsafeMutableBufferPointer { mtmd_tokenize(mc, chunks, &input, $0.baseAddress, 1) }
            }
        }
        guard status == 0 else { fail("tokenize \(status)") }
        var byType: [String: (chunks: Int, tokens: Int)] = [:]
        for index in 0..<mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, index)
            let kind = switch mtmd_input_chunk_get_type(chunk) {
            case MTMD_INPUT_CHUNK_TYPE_TEXT: "text"
            case MTMD_INPUT_CHUNK_TYPE_IMAGE: "image"
            default: "audio"
            }
            let old = byType[kind] ?? (0, 0)
            byType[kind] = (old.chunks + 1, old.tokens + mtmd_input_chunk_get_n_tokens(chunk))
        }
        print("prompt tokens: \(mtmd_helper_get_n_tokens(chunks)) \(byType.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.tokens) in \($0.value.chunks)" }.joined(separator: ", "))")

        var nPast: llama_pos = 0
        guard mtmd_helper_eval_chunks(mc, ctx, chunks, 0, 0, 512, true, &nPast) == 0 else { fail("eval") }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        // Same text-only rule as LlamaCppVLM.addTextOnlyBias.
        var bias: [llama_logit_bias] = ["<|audio_start|>", "<|mixed_start|>"].compactMap { name in
            var token: llama_token = 0
            let count = llama_tokenize(llama_model_get_vocab(model), name, Int32(name.utf8.count), &token, 1, false, true)
            return count == 1 ? llama_logit_bias(token: token, bias: -.infinity) : nil
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_logit_bias(
            llama_vocab_n_tokens(llama_model_get_vocab(model)), Int32(bias.count), &bias))
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        let vocab = llama_model_get_vocab(model)
        var batch = llama_batch_init(1, 0, 1)
        var bytes: [UInt8] = []
        for _ in 0..<256 {
            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            var piece = [CChar](repeating: 0, count: 128)
            let n = llama_token_to_piece(vocab, token, &piece, 128, 0, true)
            if n > 0 { bytes += piece.prefix(Int(n)).map { UInt8(bitPattern: $0) } }
            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = nPast
            batch.n_seq_id[0] = 1
            batch.seq_id[0]?.pointee = 0
            batch.logits[0] = 1
            guard llama_decode(ctx, batch) == 0 else { fail("decode") }
            nPast += 1
        }
        print("answer: \(String(decoding: bytes, as: UTF8.self))")
        llama_batch_free(batch)
        llama_sampler_free(sampler)
        mtmd_bitmap_free(video)
        mtmd_input_chunks_free(chunks)
        // Free Metal resources before exit; otherwise ggml-metal asserts at teardown.
        mtmd_free(mc)
        llama_free(ctx)
        llama_model_free(model)
        llama_backend_free()
    }

    static func fail(_ what: String) -> Never {
        FileHandle.standardError.write(Data("harness: \(what) failed\n".utf8))
        exit(1)
    }
}
