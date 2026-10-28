import Foundation
import Combine

struct ClassifierModelInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let window: Int
    var supportsCalibration = false
    var hasDirectAnswerHead = false
    var isImage = false
}

/// Captures the completed run independently of the next input/model draft.
/// Each successful run gets its own identity, even when its scores are identical.
struct ClassifierPrintedResult: Identifiable, Sendable {
    let id = UUID()
    let answer: CoreAIClassifierAnswer
    let model: ClassifierModelInfo
    let type: ClassifierRequest.Kind
    let elapsedSeconds: Double
}

/// One strict request shape shared by the UI and the authenticated local API.
struct ClassifierRequest: Codable, Sendable {
    enum Kind: String, CaseIterable, Codable, Identifiable, Sendable {
        case choice, score, boolean
        var id: String { rawValue }
        var title: String { switch self { case .choice: return "Choice"; case .score: return "Score"; case .boolean: return "Yes / No" } }
    }
    struct Option: Codable, Sendable { let id: String; let description: String }
    let model: String
    let input: String
    let instructions: String
    let type: Kind
    var options: [Option]? = nil
    var rubric: [String]? = nil
    var falseCriterion: String? = nil
    var trueCriterion: String? = nil
    var calibrated: Bool? = nil
    var imageData: Data? = nil

    var question: CoreAIClassifierQuestion {
        get throws {
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreAIClassifierError.invalidQuestion }
            switch type {
            case .choice:
                guard rubric == nil, falseCriterion == nil, trueCriterion == nil, let options else { throw CoreAIClassifierError.invalidQuestion }
                guard (2...20).contains(options.count), Set(options.map(\.id)).count == options.count,
                      options.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw CoreAIClassifierError.invalidQuestion }
                return .choice(instructions: instructions, options: options.map { .init(id: $0.id, description: $0.description) })
            case .score:
                guard options == nil, falseCriterion == nil, trueCriterion == nil, let rubric else { throw CoreAIClassifierError.invalidQuestion }
                guard (2...20).contains(rubric.count), rubric.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw CoreAIClassifierError.invalidQuestion }
                return .score(instructions: instructions, rubric: rubric)
            case .boolean:
                guard options == nil, rubric == nil else { throw CoreAIClassifierError.invalidQuestion }
                guard (falseCriterion == nil) == (trueCriterion == nil),
                      falseCriterion.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
                      trueCriterion.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else { throw CoreAIClassifierError.invalidQuestion }
                return .boolean(instructions: instructions, falseCriterion: falseCriterion, trueCriterion: trueCriterion)
            }
        }
    }
}

@MainActor
final class CoreAIClassifierWorkbench: ObservableObject {
    struct Backend {
        var activate: (String) async throws -> ClassifierModelInfo
        var run: (ClassifierRequest) async throws -> CoreAIClassifierAnswer
        var validate: (ClassifierRequest) async throws -> Int
        var cancel: () -> Void
        var unload: () async -> Void
    }
    enum Phase: Equatable {
        case inactive, loading, ready, running, stopping, failed(String)
        var busy: Bool { self == .loading || self == .running || self == .stopping }
        var title: String {
            switch self {
            case .inactive: return "Not active"
            case .loading: return "Activating model…"
            case .ready: return "Active on this device"
            case .running: return "Classifying…"
            case .stopping: return "Stopping…"
            case .failed: return "Needs attention"
            }
        }
    }
    enum Template: String, CaseIterable, Identifiable {
        case custom, sentiment, intent, relevance, yesNo
        var id: String { rawValue }
        var title: String { switch self { case .custom: return "Custom task"; case .sentiment: return "Sentiment"; case .intent: return "Message intent"; case .relevance: return "Relevance score"; case .yesNo: return "Yes / No check" } }
    }
    @Published var selectedModelID = ""
    @Published var type: ClassifierRequest.Kind = .choice
    @Published var input = ""
    @Published var instructions = "Choose the category that best describes the input."
    @Published var optionsText = "question: A request for information\nfeedback: Feedback or an opinion\naction: A request to do something"
    @Published var rubricText = "Unrelated\nSomewhat relevant\nHighly relevant"
    @Published var falseCriterion = "The input does not satisfy the instruction."
    @Published var trueCriterion = "The input satisfies the instruction."
    @Published var calibrated = false
    @Published var imageData: Data?
    @Published private(set) var phase: Phase = .inactive
    @Published private(set) var activeModel: ClassifierModelInfo?
    @Published private(set) var answer: CoreAIClassifierAnswer?
    @Published private(set) var answerType: ClassifierRequest.Kind?
    @Published private(set) var validationMessage: String?
    @Published private(set) var usedTokens: Int?
    @Published private(set) var savedTasks: [SavedClassifierTask] = []
    @Published private(set) var elapsedSeconds: Double?
    @Published private(set) var printedResult: ClassifierPrintedResult?
    @Published private(set) var isResultStale = false
    private let backend: Backend
    private let defaults: UserDefaults
    private static let savedTasksKey = "Classifier.savedTasks.v1"
    private var operation: Task<Void, Never>?
    private var preview: Task<Void, Never>?
    private var epoch: UInt64 = 0

    init(backend: Backend, defaults: UserDefaults = .standard) {
        self.backend = backend; self.defaults = defaults
        if let data = defaults.data(forKey: Self.savedTasksKey),
           let tasks = try? JSONDecoder().decode([SavedClassifierTask].self, from: data) { savedTasks = Array(tasks.prefix(40)) }
    }
    var isActiveSelection: Bool { activeModel?.id == selectedModelID }
    var selectedIsImage: Bool { (isActiveSelection && activeModel?.isImage == true) || ClassifierCatalog.model(id: selectedModelID)?.isImage == true }
    var hasInput: Bool { selectedIsImage ? imageData != nil : !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func request() throws -> ClassifierRequest {
        if selectedIsImage {
            guard let imageData, !imageData.isEmpty, imageData.count <= 20 * 1_024 * 1_024 else { throw CoreAIInferenceError.invalidImage("Choose an image under 20 MB.") }
            return ClassifierRequest(model: selectedModelID, input: "", instructions: "", type: .choice, imageData: imageData)
        }
        let options: [ClassifierRequest.Option]? = type == .choice ? try optionsText.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { throw CoreAIClassifierError.invalidQuestion }
            return .init(id: String(pieces[0]).trimmingCharacters(in: .whitespaces),
                         description: String(pieces[1]).trimmingCharacters(in: .whitespaces))
        } : nil
        return ClassifierRequest(model: selectedModelID, input: input, instructions: instructions, type: type,
            options: options, rubric: type == .score ? rubricText.split(separator: "\n").map(String.init) : nil,
            falseCriterion: type == .boolean ? falseCriterion : nil, trueCriterion: type == .boolean ? trueCriterion : nil,
            calibrated: calibrated && activeModel?.supportsCalibration == true)
    }

    func startActivation() {
        guard !phase.busy else { return }
        operation = Task { try? await activate(id: selectedModelID) }
    }
    func startRun() {
        guard !phase.busy else { return }
        operation = Task {
            do { try await run(request()) }
            catch { if !phase.busy { phase = .failed(error.localizedDescription) } }
        }
    }
    func activate(id: String) async throws {
        guard !phase.busy else { throw CoreAIClassifierError.busy }
        preview?.cancel()
        epoch &+= 1; let ticket = epoch
        phase = .loading; answer = nil; printedResult = nil; validationMessage = nil
        do {
            let info = try await backend.activate(id)
            try Task.checkCancellation()
            guard ticket == epoch else { throw CancellationError() }
            selectedModelID = info.id; activeModel = info; phase = .ready
            calibrated = false
            refreshValidation()
        } catch {
            if ticket == epoch { phase = error is CancellationError ? .inactive : .failed(error.localizedDescription) }
            else if phase == .stopping { phase = .inactive }
            throw error
        }
    }
    @discardableResult func run(_ request: ClassifierRequest) async throws -> CoreAIClassifierAnswer {
        guard !phase.busy else { throw CoreAIClassifierError.busy }
        preview?.cancel()
        guard let model = activeModel, model.id == request.model else { throw CoreAIInferenceError.unavailable("Activate this classifier before running it.") }
        if activeModel?.isImage == true {
            guard request.imageData != nil else { throw CoreAIInferenceError.invalidImage("Choose an image to classify.") }
        } else { _ = try request.question }
        epoch &+= 1; let ticket = epoch
        phase = .running; answer = nil; printedResult = nil; elapsedSeconds = nil
        let started = ContinuousClock.now
        do {
            let result = try await backend.run(request)
            try Task.checkCancellation()
            guard ticket == epoch else { throw CancellationError() }
            answer = result; answerType = request.type; phase = .ready
            let duration = started.duration(to: .now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            elapsedSeconds = seconds
            isResultStale = false
            printedResult = ClassifierPrintedResult(answer: result, model: model, type: request.type,
                elapsedSeconds: seconds)
            return result
        } catch {
            if ticket == epoch { phase = error is CancellationError ? (activeModel == nil ? .inactive : .ready) : .failed(error.localizedDescription) }
            else if phase == .stopping { phase = activeModel == nil ? .inactive : .ready }
            throw error
        }
    }
    func stop() {
        guard phase.busy else { return }
        epoch &+= 1; phase = .stopping; answer = nil; printedResult = nil
        operation?.cancel(); backend.cancel()
    }
    func unload() {
        stop(); preview?.cancel()
        operation = Task { await backend.unload(); runtimeDidUnload() }
    }
    func unloadAndWaitForCleanup() async {
        unload()
        await operation?.value
    }
    func runtimeDidUnload() {
        preview?.cancel()
        activeModel = nil; answer = nil; usedTokens = nil
        isResultStale = printedResult != nil
        if phase != .loading { epoch &+= 1; phase = .inactive }
    }
    func refreshValidation() {
        preview?.cancel(); usedTokens = nil; validationMessage = nil
        elapsedSeconds = nil
        answer = nil; answerType = nil
        isResultStale = printedResult != nil
        guard isActiveSelection, !phase.busy, hasInput else { return }
        preview = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let count = try await backend.validate(request())
                try Task.checkCancellation()
                usedTokens = count
            } catch is CancellationError { }
            catch { if !Task.isCancelled { validationMessage = error.localizedDescription } }
        }
    }
    func apply(_ template: Template) {
        guard !phase.busy else { return }
        answer = nil
        switch template {
        case .custom: break
        case .sentiment:
            type = .choice; instructions = "Classify the sentiment of the input."
            optionsText = "positive: Expresses a positive feeling\nneutral: Expresses no clear positive or negative feeling\nnegative: Expresses a negative feeling"
        case .intent:
            type = .choice; instructions = "Choose the main intent of this message."
            optionsText = "question: Asking for information\nfeedback: Giving feedback or an opinion\naction: Requesting an action"
        case .relevance:
            type = .score; instructions = "Rate how relevant the input is to the topic you specify here."
            rubricText = "Unrelated\nPartially relevant\nHighly relevant"
        case .yesNo:
            type = .boolean; instructions = "Does the input contain a request for help?"
            falseCriterion = "There is no request for help."; trueCriterion = "There is a request for help."
        }
        refreshValidation()
    }

    func saveTask(named rawName: String) throws {
        guard !phase.busy, !selectedIsImage else { throw CoreAIClassifierError.busy }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, savedTasks.count < 40 else { throw CoreAIInferenceError.unavailable("Use a name under 80 characters. You can save up to 40 classifiers.") }
        // Validate task structure without requiring the user to provide input.
        let draft = try request()
        _ = try ClassifierRequest(model: draft.model, input: "Task validation", instructions: draft.instructions, type: draft.type,
            options: draft.options, rubric: draft.rubric, falseCriterion: draft.falseCriterion, trueCriterion: draft.trueCriterion).question
        let task = SavedClassifierTask(id: UUID(), name: name, type: type, instructions: instructions,
            options: optionsText, rubric: rubricText, falseCriterion: falseCriterion, trueCriterion: trueCriterion)
        try persist(savedTasks + [task])
    }
    func apply(_ task: SavedClassifierTask) {
        guard !phase.busy, !selectedIsImage else { return }
        type = task.type; instructions = task.instructions; optionsText = task.options; rubricText = task.rubric
        falseCriterion = task.falseCriterion; trueCriterion = task.trueCriterion
        refreshValidation()
    }
    func deleteTask(id: UUID) throws { try persist(savedTasks.filter { $0.id != id }) }
    /// Data wipe: saved instructions are user content.
    func clearSavedTasks() {
        defaults.removeObject(forKey: Self.savedTasksKey)
        savedTasks = []
    }
    private func persist(_ tasks: [SavedClassifierTask]) throws {
        defaults.set(try JSONEncoder().encode(tasks), forKey: Self.savedTasksKey)
        savedTasks = tasks
    }
}
