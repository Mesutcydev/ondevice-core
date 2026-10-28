import Foundation
import llama

/// Original integration of llama.cpp b11558's published ModernBERT decision
/// contract. Handles belong only to the host's admitted classifier session.
enum GGUFDecisionClassifierRuntime {
    static func validateDownload(_ entry: ClassifierCatalogModel, root: URL) async throws {
        let url = try entry.assetURL(in: root)
        let flag = CancellationFlag()
        let work = Task.detached(priority: .utility) {
            _ = try Session(url: url, entry: entry, flag: flag, vocabularyOnly: true)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { flag.cancel(); work.cancel() }
        try Task.checkCancellation()
    }
    static func loadAdmitted(_ entry: ClassifierCatalogModel, root: URL,
        checkSafety: @escaping @Sendable () async throws -> Void) async throws -> CoreAIClassifierAdapter {
        let url = try entry.assetURL(in: root)
        let flag = CancellationFlag()
        let work = Task.detached(priority: .userInitiated) { try Session(url: url, entry: entry, flag: flag) }
        let session = try await withTaskCancellationHandler { try await work.value } onCancel: { flag.cancel(); work.cancel() }
        try Task.checkCancellation()
        return try CoreAIClassifierAdapter(contract: session.contract, encode: { try session.encode($0) }, runMain: { row in
            try Task.checkCancellation()
            flag.reset()
            let prediction = Task.detached(priority: .userInitiated) { try session.predict(row) }
            return try await withTaskCancellationHandler { try await prediction.value } onCancel: { flag.cancel(); prediction.cancel() }
        }, checkSafety: checkSafety)
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
        func reset() { lock.withLock { cancelled = false } }
    }

    /// Immutable native handles used exclusively by one serial adapter.
    private final class Session: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer?
        let contract: CoreAIClassifierContract
        let flag: CancellationFlag
        private static let initialize: Void = {
            // Native diagnostics may include tokenized input. Suppress them.
            llama_log_set({ _, _, _ in }, nil)
            llama_backend_init()
        }()

        init(url: URL, entry: ClassifierCatalogModel, flag: CancellationFlag, vocabularyOnly: Bool = false) throws {
            _ = Self.initialize
            self.flag = flag
            var params = llama_model_default_params()
            params.n_gpu_layers = 0
            params.vocab_only = vocabularyOnly
            params.progress_callback = { _, data in
                guard let data else { return true }
                return !Unmanaged<CancellationFlag>.fromOpaque(data).takeUnretainedValue().isCancelled
            }
            params.progress_callback_user_data = Unmanaged.passUnretained(flag).toOpaque()
            guard let loaded = llama_model_load_from_file(url.path, params) else {
                if flag.isCancelled { throw CancellationError() }; throw CoreAIClassifierError.unsupportedContract
            }
            do {
                guard Self.metadata(loaded, "general.architecture") == "modern-bert",
                      Self.metadata(loaded, "modern-bert.decision.type") == "laya",
                      (vocabularyOnly || llama_model_n_embd_out(loaded) == 3),
                      let head = Self.metadata(loaded, "modern-bert.decision.max_head_tokens").flatMap(Int.init),
                      let vocab = llama_model_get_vocab(loaded) else { throw CoreAIClassifierError.unsupportedContract }
                let kinds = ["choice", "score", "noul"]
                let temperatures = kinds.map { Self.metadata(loaded, "modern-bert.decision.temperature.\($0)").flatMap(Double.init) }
                var buckets: [String: Double] = [:]
                for kind in kinds {
                    for (native, key) in [("2", "2"), ("3_5", "3-5"), ("6_10", "6-10"), ("11", "11+")] {
                        if let text = Self.metadata(loaded, "modern-bert.decision.temperature.\(kind).\(native)") {
                            guard let value = Double(text), value.isFinite, value > 0 else { throw CoreAIClassifierError.unsupportedContract }
                            buckets["\(kind):\(key)"] = value
                        }
                    }
                }
                contract = try CoreAIClassifierContract(layout: entry.layout, window: entry.window, headBudget: min(head, entry.window),
                    vocabSize: Int(llama_vocab_n_tokens(vocab)), cls: llama_vocab_bos(vocab), sep: llama_vocab_sep(vocab), pad: llama_vocab_pad(vocab), mask: llama_vocab_mask(vocab),
                    sourceTemperatures: temperatures.map { $0 ?? 1 },
                    calibratedTemperatures: entry.layout == .laya && temperatures.allSatisfy({ $0 != nil }) ? temperatures.compactMap { $0 } : nil,
                    temperatureBuckets: entry.layout == .laya ? buckets : [:])
                if vocabularyOnly { model = loaded; context = nil; return }
                var settings = llama_context_default_params()
                settings.n_ctx = UInt32(entry.window); settings.n_batch = UInt32(entry.window); settings.n_ubatch = UInt32(entry.window)
                settings.n_seq_max = 1; settings.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)); settings.n_threads_batch = settings.n_threads
                settings.embeddings = true; settings.pooling_type = LLAMA_POOLING_TYPE_NONE
                settings.attention_type = LLAMA_ATTENTION_TYPE_NON_CAUSAL
                settings.offload_kqv = false; settings.op_offload = false
                settings.abort_callback = { data in
                    guard let data else { return false }
                    return Unmanaged<CancellationFlag>.fromOpaque(data).takeUnretainedValue().isCancelled
                }
                settings.abort_callback_data = Unmanaged.passUnretained(flag).toOpaque()
                guard let created = llama_init_from_model(loaded, settings) else { throw CoreAIClassifierError.unsupportedContract }
                model = loaded; context = created
            } catch { llama_model_free(loaded); throw error }
        }
        deinit { if let context { llama_free(context) }; llama_model_free(model) }

        func encode(_ text: String) throws -> [Int32] {
            guard let vocab = llama_model_get_vocab(model), let length = Int32(exactly: text.utf8.count) else { throw CoreAIClassifierError.invalidToken }
            let required = -llama_tokenize(vocab, text, length, nil, 0, false, false)
            guard required >= 0, required <= 16_384 else { throw CoreAIClassifierError.stateTooLong }
            var tokens = [Int32](repeating: 0, count: Int(required))
            guard llama_tokenize(vocab, text, length, &tokens, required, false, false) == required else { throw CoreAIClassifierError.invalidToken }
            return tokens
        }
        func predict(_ row: CoreAIClassifierInput) throws -> CoreAIClassifierOutput {
            guard let context else { throw CoreAIClassifierError.unsupportedContract }
            try Task.checkCancellation()
            guard !flag.isCancelled else { throw CancellationError() }
            if let memory = llama_get_memory(context) { llama_memory_clear(memory, true) }
            var batch = llama_batch_init(Int32(row.realTokenCount), 0, 1)
            defer { llama_batch_free(batch) }
            batch.n_tokens = Int32(row.realTokenCount)
            let markers = Set(row.markers)
            for i in 0..<row.realTokenCount {
                batch.token[i] = row.inputIDs[i]; batch.pos[i] = Int32(i)
                batch.n_seq_id[i] = 1; batch.seq_id[i]?[0] = 0
                batch.logits[i] = markers.contains(i) ? 1 : 0
            }
            let status = llama_model_has_encoder(model) ? llama_encode(context, batch) : llama_decode(context, batch)
            try Task.checkCancellation()
            guard !flag.isCancelled else { throw CancellationError() }
            guard status == 0, let column = row.questionType.firstIndex(of: 1) else { throw CoreAIClassifierError.invalidOutput }
            var logits = [Float](repeating: 0, count: contract.window)
            for marker in row.markers {
                guard let scores = llama_get_embeddings_ith(context, Int32(marker)), scores[column].isFinite else { throw CoreAIClassifierError.invalidOutput }
                logits[marker] = scores[column]
            }
            return .init(tokenLogits: logits)
        }
        private static func metadata(_ model: OpaquePointer, _ key: String) -> String? {
            var buffer = [CChar](repeating: 0, count: 1_024)
            let count = llama_model_meta_val_str(model, key, &buffer, buffer.count)
            guard count >= 0, count < buffer.count else { return nil }
            return String(cString: buffer)
        }
    }
}
