import Foundation

#if LFM3_OMNI
/// LFM3-Omni speech in and out through llama.cpp b11960's mtmd API. Shared by
/// the app's bridge and scripts/tests/omni-video-harness. The caller owns the
/// model, context and mtmd context and runs one request at a time.
enum OmniSpeech {
    enum Failure: LocalizedError {
        case noSpeechOutput, noSpeechInput, cancelled
        case step(String)

        var errorDescription: String? {
            switch self {
            case .noSpeechOutput: "This model cannot speak."
            case .noSpeechInput: "This model cannot listen."
            case .cancelled: "Cancelled."
            case .step(let what): "LFM3 Omni speech failed at \(what)."
            }
        }
    }

    struct Audio: Sendable {
        let sampleRate: Int
        /// 16-bit mono WAV, as llama-tts writes it.
        let wav: Data
    }

    /// llama.cpp's text-only rule (mtmd-helper-gen): a text answer never opens
    /// an audio or mixed text+speech segment.
    static func textOnlyBias(_ vocab: OpaquePointer?) -> [llama_logit_bias] {
        ["<|audio_start|>", "<|mixed_start|>"].compactMap { name in
            var token: llama_token = 0
            let count = llama_tokenize(vocab, name, Int32(name.utf8.count), &token, 1, false, true)
            return count == 1 ? llama_logit_bias(token: token, bias: -.infinity) : nil
        }
    }

    /// llama-tts's loop: the model's "tts" prompt, then one backbone token and
    /// one 80 ms audio frame per step until the end-of-audio frame. Audio
    /// frames use the model card's sampling, stored in the projector.
    static func synthesize(
        _ text: String, language: String?, voice: String?,
        model: OpaquePointer, context: OpaquePointer, mtmd: OpaquePointer,
        maxFrames: Int = 1_500, isCancelled: () -> Bool = { false }
    ) throws -> Audio {
        guard mtmd_gen_audio_get_info(mtmd).type != MTMD_GEN_AUDIO_TYPE_NONE else { throw Failure.noSpeechOutput }
        llama_memory_clear(llama_get_memory(context), false)
        llama_set_embeddings(context, true)
        defer {
            llama_set_embeddings(context, false)
            llama_memory_clear(llama_get_memory(context), false)
        }
        guard let gen = mtmd_helper_gen_audio_init(context, mtmd) else { throw Failure.step("init") }
        defer { mtmd_helper_gen_audio_free(gen) }

        let status: Int32 = LFM3Catalog.speechPrompt(text, language: language, voice: voice).withCString { prompt in
            var input = mtmd_helper_gen_audio_inp_default()
            input.seq_id = 0
            input.prompt = prompt
            input.prompt_len = strlen(prompt)
            input.out_type = MTMD_HELPER_GEN_AUDIO_OUTTYPE_WAV
            return mtmd_helper_gen_audio_set_input(gen, &input)
        }
        guard status == 0 else { throw Failure.step("prompt setup") }
        while true {
            let left = mtmd_helper_gen_audio_step_prompt(gen, 512)
            guard left >= 0 else { throw Failure.step("prompt") }
            if left == 0 { break }
        }

        // The backbone token is sampled like llama-tts (common_sampler defaults).
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw Failure.step("sampler") }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.8))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        func sample() -> llama_token {
            let token = llama_sampler_sample(sampler, context, -1)
            llama_sampler_accept(sampler, token)
            return token
        }

        var sampled = sample()
        var state: UnsafePointer<Float>? = UnsafePointer(llama_get_embeddings_ith(context, -1))
        var stop = false
        var frames = 0
        while !stop, frames < maxFrames {
            guard !isCancelled() else { throw Failure.cancelled }
            var next: UnsafePointer<Float>?
            guard mtmd_helper_gen_audio_step_gen(gen, sampled, state, &next, &stop) == 0 else {
                throw Failure.step("frame \(frames)")
            }
            guard let next else { break }
            frames += 1
            state = next
            sampled = sample()
        }

        var rate: Int32 = 0
        var data: UnsafePointer<CChar>?
        var length = 0
        var samples: Int64 = 0
        guard mtmd_helper_gen_audio_get_output(gen, &rate, &data, &length, &samples) == 0,
              let data, length > 0, samples > 0 else { throw Failure.noSpeechOutput }
        return Audio(sampleRate: Int(rate), wav: Data(bytes: data, count: length))
    }

    /// Speech to text: the recording (mono, at the audio encoder's rate) as
    /// the user turn of the card's "Perform ASR in …" prompt; greedy text.
    static func transcribe(
        _ samples: [Float], language: String?,
        model: OpaquePointer, context: OpaquePointer, mtmd: OpaquePointer,
        maxTokens: Int = 448, isCancelled: () -> Bool = { false }
    ) throws -> String {
        guard mtmd_support_audio(mtmd), !samples.isEmpty else { throw Failure.noSpeechInput }
        llama_memory_clear(llama_get_memory(context), false)
        guard let audio = samples.withUnsafeBufferPointer({ mtmd_bitmap_init_from_audio($0.count, $0.baseAddress) })
        else { throw Failure.step("audio") }
        defer { mtmd_bitmap_free(audio) }

        let prompt = LFM3Catalog.transcriptionPrompt(marker: String(cString: mtmd_get_marker(mtmd)), language: language)
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        let status: Int32 = prompt.withCString { text in
            var input = mtmd_input_text()
            input.text = text
            input.text_len = strlen(text)
            input.add_special = true
            input.parse_special = true
            var media: [OpaquePointer?] = [audio]
            return media.withUnsafeMutableBufferPointer { mtmd_tokenize(mtmd, chunks, &input, $0.baseAddress, 1) }
        }
        guard status == 0 else { throw Failure.step("tokenize \(status)") }
        var past: llama_pos = 0
        guard mtmd_helper_eval_chunks(mtmd, context, chunks, 0, 0, 512, true, &past) == 0 else {
            throw Failure.step("listening")
        }

        let vocab = llama_model_get_vocab(model)
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw Failure.step("sampler") }
        defer { llama_sampler_free(sampler) }
        var bias = textOnlyBias(vocab)
        llama_sampler_chain_add(sampler, llama_sampler_init_logit_bias(llama_vocab_n_tokens(vocab), Int32(bias.count), &bias))
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }
        var bytes: [UInt8] = []
        for _ in 0..<maxTokens {
            guard !isCancelled() else { throw Failure.cancelled }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            var piece = [CChar](repeating: 0, count: 128)
            let count = llama_token_to_piece(vocab, token, &piece, 128, 0, false)
            if count > 0 { bytes += piece.prefix(Int(count)).map { UInt8(bitPattern: $0) } }
            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = past
            batch.n_seq_id[0] = 1
            batch.seq_id[0]?.pointee = 0
            batch.logits[0] = 1
            guard llama_decode(context, batch) == 0 else { throw Failure.step("decode") }
            past += 1
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
