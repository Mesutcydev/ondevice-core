import Foundation
import Combine
import UIKit

/// Small app-facing facade. The Core AI SDK is isolated behind this type so
/// the existing API server and safety/lifecycle code do not import SDK types.
@MainActor
final class CoreAIInferenceService: ObservableObject {
    static let shared = CoreAIInferenceService()

    @Published private(set) var isReady = false
    /// Assistant selection id (`coreai:…`) of the pack currently specialized.
    /// `isReady` alone is not enough: the store can point at pack B while
    /// this runtime still holds pack A.
    @Published private(set) var loadedSelectionID: String?
    @Published private(set) var loadedClassifierID: String?
    private var classifier: CoreAIClassifierAdapter?
    private var classifierLoadTask: Task<CoreAIClassifierAdapter, Error>?
    private var loadingClassifierID: String?
    private var classifierOperation: Task<CoreAIClassifierAnswer, Error>?
    private var textLoadTask: Task<CoreAIRuntime, Error>?
    private var loadingSelectionID: String?
    private var lifetime: UInt64 = 0
    private var unloadTask: Task<Void, Never>?
    private var unloadingPackIDs: Set<String> = []
    private var backgroundObserver: NSObjectProtocol?
    private var runtime: CoreAIRuntime?

    /// An in-flight specialization may already be reading pack files before
    /// the loaded identity is published. Removal must drain it as well.
    func isUsingPack(_ selectionID: String) -> Bool {
        unloadingPackIDs.contains(selectionID)
            || [loadedSelectionID, loadedClassifierID, loadingSelectionID, loadingClassifierID].contains(selectionID)
    }

    private init() {
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                if self.classifier != nil || self.classifierLoadTask != nil { await self.unload() }
            }
        }
    }

    func isLoaded(as selectionID: String) -> Bool {
        Self.isCurrentRuntime(
            loadedID: loadedSelectionID,
            ready: isReady,
            requestedID: selectionID
        )
    }

    nonisolated static func normalizedSelectionID(_ id: String) -> String {
        id.hasPrefix("coreai:") ? id : "coreai:\(id)"
    }

    nonisolated static func isCurrentRuntime(
        loadedID: String?,
        ready: Bool,
        requestedID: String
    ) -> Bool {
        ready
            && loadedID.map(normalizedSelectionID)
                == normalizedSelectionID(requestedID)
    }

    func load() async throws {
        guard #available(iOS 27.0, *) else {
            throw CoreAIInferenceError.unavailable("Core AI requires iOS 27 or later.")
        }
        guard let url = CoreAIModelStore.shared.modelResourcesURL,
              let manifest = CoreAIModelStore.shared.manifest else {
            throw CoreAIInferenceError.modelMissing
        }
        guard manifest.capabilities.textGeneration,
              manifest.capabilities.classification != true,
              CoreAIZooCatalog.isTextGenerationPack(id: manifest.id) else {
            throw CoreAIInferenceError.unsupportedCapability("text generation")
        }
        if let restriction = AppStoreModelPolicy.restriction(for: manifest.id) {
            throw CoreAIInferenceError.unavailable(restriction)
        }
        let selectionID = CoreAIInstalledModel.assistantSelectionID(for: manifest.id)
        if isLoaded(as: selectionID), runtime != nil {
            return
        }

        Diagnostics.shared.breadcrumb(
            "Core AI runtime load start · \(manifest.id) · v\(manifest.version) · resources=\(url.lastPathComponent)",
            category: "coreai"
        )
        await unload()
        let ticket = lifetime
        let pending = Task { @MainActor in
            let runtime = self.makeRuntime()
            try await runtime.load(resourcesAt: url)
            try Task.checkCancellation()
            return runtime
        }
        textLoadTask = pending
        loadingSelectionID = selectionID
        let runtime: CoreAIRuntime
        do {
            runtime = try await pending.value
            try Task.checkCancellation()
            guard ticket == lifetime else { throw CancellationError() }
            textLoadTask = nil
            loadingSelectionID = nil
        } catch {
            // A failed reload must not leave the previous multi-gigabyte
            // runtime resident (and `isReady` true) while the service state
            // reports failure — memory admission and the API's readiness
            // gate would both be lying.
            if ticket == lifetime { await unload() }
            Diagnostics.shared.error(
                "Core AI runtime load failed · \(manifest.id) · \(error.localizedDescription)",
                category: "coreai"
            )
            throw error
        }
        self.runtime = runtime
        loadedSelectionID = selectionID
        isReady = true
        Diagnostics.shared.breadcrumb("Core AI runtime ready · \(manifest.id)", category: "coreai")
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        thinkingEnabled: Bool?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws {
        guard isReady, let runtime else { throw CoreAIInferenceError.modelMissing }
        if messages.contains(where: \.hasAttachedImages) {
            throw CoreAIInferenceError.invalidImage(
                "This Core AI text pack does not accept images. Use Lens or an MLX/GGUF vision model."
            )
        }
        try await runtime.generate(
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            thinkingEnabled: thinkingEnabled,
            onToken: onToken
        )
    }

    func cancel() {
        runtime?.cancel()
    }

    func loadClassifier(id: String) async throws -> ClassifierModelInfo {
        guard let installed = CoreAIModelStore.shared.installedModel(id: id),
              installed.manifest.capabilities.classification == true || CoreAIZooCatalog.model(forSelectionID: id)?.category == .classifier else {
            throw CoreAIInferenceError.unavailable("Install a supported classifier from Models first.")
        }
        let selection = installed.assistantSelectionID
        if loadedClassifierID == selection, let classifier {
            return await classifierInfo(classifier, installed: installed)
        }
        // Uses the same drain-before-load path as Assistant, Lens and Image.
        try await ModelResidency.shared.prepareForClassifier()
        try Task.checkCancellation()
        if let reason = MemoryAdvisor.safetyBlocker(for: selection, runtime: .coreAI) {
            throw CoreAIInferenceError.unavailable(reason)
        }
        try Self.checkClassifierSafety()
        let ticket = lifetime
        let pending = Task { @MainActor in
            #if canImport(CoreAI)
            let adapter = try await CoreAIClassifierRuntime.loadAdmittedAdapter(resourcesAt: installed.resourcesURL, checkSafety: {
                try await MainActor.run { try Self.checkClassifierSafety() }
            })
            try Task.checkCancellation()
            return adapter
            #else
            throw CoreAIInferenceError.unavailable("Core AI classifiers require the iOS 27 device runtime.")
            #endif
        }
        classifierLoadTask = pending
        loadingClassifierID = selection
        do {
            let adapter = try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: { pending.cancel() }
            try Task.checkCancellation()
            guard ticket == lifetime else { throw CancellationError() }
            classifierLoadTask = nil; loadingClassifierID = nil
            classifier = adapter; loadedClassifierID = selection
            return await classifierInfo(adapter, installed: installed)
        } catch {
            if ticket == lifetime { classifierLoadTask = nil; loadingClassifierID = nil }
            throw error
        }
    }

    func classify(_ request: ClassifierRequest) async throws -> CoreAIClassifierAnswer {
        guard loadedClassifierID == request.model, let classifier else {
            throw CoreAIInferenceError.unavailable("Activate this classifier before running it.")
        }
        guard classifierOperation == nil else { throw CoreAIClassifierError.busy }
        try Self.checkClassifierSafety()
        let question = try request.question
        let ticket = lifetime
        ModelResidency.shared.cancelPrefetch()
        let pending = Task {
            try await classifier.classify(state: request.input, question: question,
                calibration: request.calibrated == true ? .published : .source)
        }
        classifierOperation = pending
        defer { if lifetime == ticket { classifierOperation = nil } }
        return try await withTaskCancellationHandler {
            let answer = try await pending.value
            try Task.checkCancellation()
            guard lifetime == ticket else { throw CancellationError() }
            return answer
        } onCancel: {
            pending.cancel()
            Task { await classifier.cancel() }
        }
    }

    func validateClassifier(_ request: ClassifierRequest) async throws -> Int {
        guard loadedClassifierID == request.model, let classifier else { throw CoreAIInferenceError.modelMissing }
        return try await classifier.validate(state: request.input, question: request.question)
    }

    func cancelClassifier() {
        classifierLoadTask?.cancel(); classifierOperation?.cancel()
        if let classifier { Task { await classifier.cancel() } }
    }

    private func classifierInfo(_ adapter: CoreAIClassifierAdapter, installed: CoreAIInstalledModel) async -> ClassifierModelInfo {
        let contract = adapter.contract
        return ClassifierModelInfo(id: installed.assistantSelectionID, name: installed.manifest.displayName,
            window: contract.window, supportsCalibration: contract.calibratedTemperatures != nil,
            hasDirectAnswerHead: contract.actFunction != nil)
    }

    private static func checkClassifierSafety() throws {
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
        if let reason = DeviceSafetyMonitor.shared.stopReason { throw CoreAIInferenceError.unavailable(reason.detail) }
        if MemoryAdvisor.processAvailableMemory < 128_000_000 {
            throw CoreAIInferenceError.unavailable("Not enough memory to safely run the classifier. Unload the model and free memory before retrying.")
        }
    }

    func unload() async {
        if let unloadTask { await unloadTask.value; return }
        // Published readiness clears immediately, but SDK jobs can still hold
        // these files until the asynchronous drain completes.
        unloadingPackIDs = Set([loadedSelectionID, loadedClassifierID, loadingSelectionID, loadingClassifierID].compactMap { $0 })
        lifetime &+= 1
        isReady = false; loadedSelectionID = nil; loadedClassifierID = nil
        runtime?.cancel(); textLoadTask?.cancel(); cancelClassifier()
        let textLoad = textLoadTask, load = classifierLoadTask, operation = classifierOperation
        let pending = Task { @MainActor in
            if let textLoad { _ = try? await textLoad.value }
            if let load { _ = try? await load.value }
            if let operation { _ = try? await operation.value }
            self.runtime = nil; self.classifier = nil
            self.textLoadTask = nil; self.classifierLoadTask = nil; self.classifierOperation = nil
            self.loadingSelectionID = nil; self.loadingClassifierID = nil
        }
        unloadTask = pending
        await pending.value
        unloadTask = nil
        unloadingPackIDs.removeAll()
    }
}

@MainActor
private protocol CoreAIRuntime: AnyObject, Sendable {
    func load(resourcesAt url: URL) async throws
    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        thinkingEnabled: Bool?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws
    func cancel()
}

#if canImport(FoundationModels) && canImport(CoreAILanguageModels)
import FoundationModels
import CoreAILanguageModels

@available(iOS 27.0, *)
@MainActor
private final class CoreAIAvailableRuntime: CoreAIRuntime {
    private var model: CoreAILanguageModel?
    private var task: Task<Void, Error>?

    func load(resourcesAt url: URL) async throws {
        model = try await CoreAILanguageModel(resourcesAt: url)
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        thinkingEnabled: Bool?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let model else { throw CoreAIInferenceError.modelMissing }
        guard let plan = CoreAIConversationPlanner.plan(messages: messages) else {
            throw CoreAIInferenceError.emptyConversation
        }

        var entries: [Transcript.Entry] = []
        if !plan.system.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: plan.system))],
                toolDefinitions: []
            )))
        }
        for turn in plan.history {
            switch turn {
            case .user(let text):
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: text))]
                )))
            case .assistant(let text):
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: text))]
                )))
            case .tool(let id, let name, let content):
                // A stored tool result may not have a matching ToolCall in
                // this compact history. FoundationModels rejects orphaned
                // ToolOutput entries, so pass it as a user-visible prompt.
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(
                        content: "Tool result (\(name), \(id)): \(content)"
                    ))]
                )))
            }
        }

        let session = LanguageModelSession(
            model: model.withThinkingEnabled(thinkingEnabled),
            transcript: Transcript(entries: entries)
        )
        // The stream only stops through task cancellation (this SDK build
        // has no `stopResponding`), so the generation runs in a tracked
        // child task that `cancel()` can actually reach.
        let generation = Task<Void, Error> {
            var sentVisibleText = false
            func run(_ session: LanguageModelSession, prompt: String) async throws {
                let transcriptCountBefore = session.transcript.count
                var previous = ""
                for try await snapshot in session.streamResponse(
                    to: prompt,
                    options: FoundationModels.GenerationOptions(
                        temperature: temperature,
                        maximumResponseTokens: maxTokens
                    )
                ) {
                    try Task.checkCancellation()
                    let full = snapshot.content
                    let delta = ApplePrivateCloud.streamDelta(previous: previous, full: full)
                    previous = full
                    if !delta.isEmpty {
                        sentVisibleText = true
                        onToken(delta)
                    }
                }
                for entry in session.transcript.dropFirst(transcriptCountBefore) {
                    guard case .toolCalls(let calls) = entry else { continue }
                    for call in calls {
                        onToken(Self.hermesEnvelope(
                            id: call.id,
                            name: call.toolName,
                            argumentsJSON: call.arguments.jsonString
                        ))
                    }
                }
            }
            do {
                try await run(session, prompt: plan.latestUser)
            } catch {
                guard !sentVisibleText, !plan.history.isEmpty,
                      let languageError = error as? LanguageModelError else { throw error }
                switch languageError {
                case .unsupportedTranscriptContent, .contextSizeExceeded:
                    Diagnostics.shared.breadcrumb(
                        "Core AI retrying with compact recent context",
                        category: "coreai"
                    )
                    let recent = plan.history.suffix(4).map { turn -> String in
                        switch turn {
                        case .user(let text): return "User: \(text)"
                        case .assistant(let text):
                            return "Assistant: \(text.replacingOccurrences(of: "<unk>", with: ""))"
                        case .tool(_, let name, let content): return "Tool \(name): \(content)"
                        }
                    }.joined(separator: "\n")
                    let compactContext = String(recent.suffix(480))
                    let fallbackPrompt = "Recent conversation:\n\(compactContext)\n\nLatest user message:\n\(plan.latestUser)"
                    let systemEntries = entries.filter {
                        if case .instructions = $0 { return true }
                        return false
                    }
                    let fallback = LanguageModelSession(
                        model: model.withThinkingEnabled(thinkingEnabled),
                        transcript: Transcript(entries: systemEntries)
                    )
                    try await run(fallback, prompt: fallbackPrompt)
                default:
                    throw error
                }
            }
        }
        task = generation
        defer { task = nil }
        try await generation.value
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private nonisolated static func hermesEnvelope(
        id: String,
        name: String,
        argumentsJSON: String
    ) -> String {
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)
        )) as? [String: Any] ?? [:]
        // Include the model-supplied call id when it round-trips; the
        // server parser generates a stable id otherwise.
        let payload: [String: Any] = [
            "id": id,
            "name": name,
            "arguments": arguments
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ),
              let json = String(data: data, encoding: .utf8) else {
            return "<tool_call>{\"name\":\"\(name)\",\"arguments\":{}}</tool_call>"
        }
        return "<tool_call>\(json)</tool_call>"
    }
}
#endif

@MainActor
private final class CoreAIUnavailableRuntime: CoreAIRuntime {
    func load(resourcesAt url: URL) async throws {
        throw CoreAIInferenceError.unavailable("Build this target with the Xcode 27 SDK to use Core AI.")
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        thinkingEnabled: Bool?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws {
        throw CoreAIInferenceError.unavailable("Core AI is unavailable in this build.")
    }

    func cancel() {}
}

private extension CoreAIInferenceService {
    func makeRuntime() -> CoreAIRuntime {
        #if canImport(FoundationModels) && canImport(CoreAILanguageModels)
        if #available(iOS 27.0, *) { return CoreAIAvailableRuntime() }
        #endif
        return CoreAIUnavailableRuntime()
    }
}
