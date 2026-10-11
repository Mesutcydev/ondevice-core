import SwiftUI
import OnDeviceUI

/// Native classifier workspace. Drafts remain mounted with the workbench;
/// only explicit Activate/Classify actions claim the shared model runtime.
struct CoreAIClassifierWorkbenchView: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    let models: [ClassifierModelInfo]
    let onOpenMenu: () -> Void
    let onActivate: () -> Void
    let onRun: () -> Void
    @State private var template: CoreAIClassifierWorkbench.Template = .custom
    @FocusState private var editing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            Form {
                ClassifierModelSection(controller: controller, models: models, onActivate: onActivate)
                Section("Task") {
                    Picker("Start from", selection: $template) {
                        ForEach(CoreAIClassifierWorkbench.Template.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("classifier.template")
                    ClassifierTaskPicker(type: $controller.type)
                    TextField("What should the model decide?", text: $controller.instructions, axis: .vertical)
                        .lineLimit(2...6).focused($editing)
                        .accessibilityLabel("Classifier instructions").accessibilityIdentifier("classifier.instructions")
                }.disabled(controller.phase.busy)
                ClassifierQuestionSection(controller: controller, editing: $editing)
                Section {
                    TextField("Paste or type text to classify", text: $controller.input, axis: .vertical)
                        .lineLimit(5...14).focused($editing)
                        .accessibilityIdentifier("classifier.input")
                        .disabled(controller.phase.busy)
                } header: { Text("Input") } footer: {
                    if let message = controller.validationMessage {
                        Text(message).foregroundStyle(.red).accessibilityIdentifier("classifier.validation")
                    } else if let used = controller.usedTokens, let model = controller.activeModel {
                        Text("\(used) of \(model.window) tokens used. Input stays on this device.")
                    } else {
                        Text("Input stays on this device. Long inputs and options are checked against the model’s limits.")
                    }
                }
                if controller.activeModel?.supportsCalibration == true {
                    Section {
                        Toggle("Published calibration", isOn: $controller.calibrated)
                            .disabled(controller.phase.busy).accessibilityIdentifier("classifier.calibration")
                    } footer: { Text("Use the publisher’s fitted probability calibration for this model.") }
                }
                Section {
                    if controller.phase.busy {
                        Button("Stop", role: .destructive) { controller.stop() }
                            .disabled(controller.phase == .stopping).accessibilityIdentifier("classifier.stop")
                    } else {
                        Button { editing = false; onRun() } label: {
                            Label("Classify", systemImage: "checklist")
                                .font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                        }
                        .disabled(!controller.isActiveSelection || controller.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.validationMessage != nil)
                        .accessibilityIdentifier("classifier.run")
                    }
                    if case .failed(let message) = controller.phase {
                        Text(message).foregroundStyle(.red).accessibilityIdentifier("classifier.error")
                    }
                }
                if let answer = controller.answer {
                    ClassifierResultSection(answer: answer, type: controller.answerType)
                        .id("classifier-result")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: controller.answer != nil) { _, available in
                if available {
                    if reduceMotion { scroll.scrollTo("classifier-result", anchor: .top) }
                    else { withAnimation { scroll.scrollTo("classifier-result", anchor: .top) } }
                }
            }
            }
            .navigationTitle("Classifiers").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenMenu) { Image(systemName: "line.3.horizontal") }
                        .accessibilityLabel("Open app menu").accessibilityIdentifier("navigation.menu")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { editing = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Hide keyboard")
                    Spacer()
                }
            }
            .tint(.primary)
            .onAppear { if controller.selectedModelID.isEmpty { controller.selectedModelID = models.first?.id ?? "" } }
            .onChange(of: models.map(\.id)) { _, ids in
                if !ids.contains(controller.selectedModelID) { controller.selectedModelID = ids.first ?? "" }
            }
            .onChange(of: controller.calibrated) { _, _ in controller.refreshValidation() }
            .onChange(of: template) { _, value in controller.apply(value) }
            .onChange(of: [controller.input, controller.instructions, controller.optionsText, controller.rubricText, controller.falseCriterion, controller.trueCriterion, controller.selectedModelID, controller.type.rawValue]) { _, _ in controller.refreshValidation() }
        }
    }
}

private struct ClassifierTaskPicker: View {
    @Binding var type: ClassifierRequest.Kind
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if typeSize.isAccessibilitySize {
            Picker("Decision", selection: $type) {
                ForEach(ClassifierRequest.Kind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("classifier.type")
        } else {
            Picker("Decision", selection: $type) {
                ForEach(ClassifierRequest.Kind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("classifier.type")
        }
    }
}

private struct ClassifierModelSection: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    let models: [ClassifierModelInfo]
    let onActivate: () -> Void
    var body: some View {
        Section {
            if models.isEmpty {
                Text("Download a classifier from Models → Discover → Classifiers.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $controller.selectedModelID) {
                    ForEach(models) { Text($0.name).tag($0.id) }
                }.disabled(controller.phase.busy).accessibilityIdentifier("classifier.model")
                HStack {
                    if controller.phase.busy { ProgressView().accessibilityHidden(true) }
                    Label(controller.isActiveSelection ? controller.phase.title : (controller.phase.busy ? controller.phase.title : "Not active"), systemImage: controller.isActiveSelection ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.secondary).accessibilityIdentifier("classifier.status")
                    Spacer()
                    if let model = models.first(where: { $0.id == controller.selectedModelID }) {
                        Text("\(model.window) tokens").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if !controller.isActiveSelection {
                    Button("Activate model", action: onActivate)
                        .disabled(controller.phase.busy || controller.selectedModelID.isEmpty)
                        .accessibilityIdentifier("classifier.activate")
                }
                if controller.activeModel != nil {
                    Button("Unload model") { controller.unload() }
                        .disabled(controller.phase.busy).accessibilityIdentifier("classifier.unload")
                }
            }
        } header: { Text("On-device model") } footer: {
            Text("Activating a classifier releases the other active model. You can return to Assistant and reload it later.")
        }
    }
}

private struct ClassifierQuestionSection: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    let editing: FocusState<Bool>.Binding
    var body: some View {
        Section {
            switch controller.type {
            case .choice:
                TextField("id: description, one per line", text: $controller.optionsText, axis: .vertical)
                    .lineLimit(3...12).focused(editing).accessibilityLabel("Choice options").accessibilityIdentifier("classifier.options")
                Text("2–20 options, one per line: ID: description. IDs must be unique; descriptions can be up to 48 tokens.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .score:
                TextField("One rubric level per line", text: $controller.rubricText, axis: .vertical)
                    .lineLimit(3...12).focused(editing).accessibilityLabel("Score rubric").accessibilityIdentifier("classifier.rubric")
                Text("Order 2–20 levels from lowest to highest. The result is the expected level index, starting at zero.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .boolean:
                TextField("When is the answer No?", text: $controller.falseCriterion, axis: .vertical)
                    .focused(editing).accessibilityLabel("No criterion").accessibilityIdentifier("classifier.falseCriterion")
                TextField("When is the answer Yes?", text: $controller.trueCriterion, axis: .vertical)
                    .focused(editing).accessibilityLabel("Yes criterion").accessibilityIdentifier("classifier.trueCriterion")
            }
        } header: { Text(controller.type == .choice ? "Options" : controller.type == .score ? "Rubric" : "Decision criteria") }
            .disabled(controller.phase.busy)
    }
}

private struct ClassifierResultSection: View {
    let answer: CoreAIClassifierAnswer
    let type: ClassifierRequest.Kind?
    var body: some View {
        Section {
            if let choice = answer.choice {
                LabeledContent("Best match", value: choice).font(.headline).accessibilityIdentifier("classifier.result.choice")
            }
            if let score = answer.score {
                LabeledContent("Expected score") { Text(score, format: .number.precision(.fractionLength(2))) }
                    .accessibilityIdentifier("classifier.result.score")
            }
            if let yes = answer.trueProbability {
                LabeledContent("Yes probability") { Text(yes, format: .percent.precision(.fractionLength(1))) }
                    .accessibilityIdentifier("classifier.result.boolean")
            }
            ForEach(Array(zip(answer.optionIDs, answer.probabilities)), id: \.0) { id, probability in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(id); Spacer(); Text(probability, format: .percent.precision(.fractionLength(1))).monospacedDigit() }
                    ProgressView(value: probability).tint(.primary)
                }
            }
            if let direct = answer.directAnswerProbability {
                LabeledContent("Direct-answer confidence") { Text(direct, format: .percent.precision(.fractionLength(1))) }
                Text("The model’s advisory estimate for answering directly. It does not start actions or tools.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ShareLink(item: ClassifierResultExport.json(answer)) { Label("Export result JSON", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("classifier.export")
        } header: { Text("Result") }
    }
}
