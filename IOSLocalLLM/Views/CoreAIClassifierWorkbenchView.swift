import SwiftUI
import OnDeviceUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

/// Native classifier workspace. Drafts remain mounted with the workbench;
/// only explicit Activate/Classify actions claim the shared model runtime.
struct CoreAIClassifierWorkbenchView: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    let models: [ClassifierModelInfo]
    let onOpenMenu: () -> Void
    let onActivate: () -> Void
    let onRun: () -> Void
    var onOpenModels: () -> Void = {}
    @State private var showSavedTasks = false
    @State private var showTaskEditor = false
    @State private var inspectedResult: ClassifierPrintedResult?
    @FocusState private var editing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.odWorkspaceVisible) private var workspaceVisible
    @Environment(\.odSidebarPinned) private var sidebarPinned

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: ODLayout.groupGap) {
                        ClassifierPrintStage(phase: controller.phase, isLoaded: controller.isActiveSelection,
                            result: controller.printedResult, isStale: controller.isResultStale,
                            isWatching: editing, onActivate: {
                                editing = false
                                if !models.isEmpty, !controller.phase.busy, !controller.isActiveSelection { onActivate() }
                            }, onOpenTicket: { inspectedResult = $0 })
                            .padding(.vertical, ODLayout.labelGap)
                            .id("classifier-stage")
                        ClassifierModelSummary(controller: controller, models: models,
                            onActivate: onActivate, onOpenModels: onOpenModels)
                        if controller.selectedIsImage {
                            ClassifierImageSection(controller: controller)
                        } else {
                            ClassifierTextInput(controller: controller, editing: $editing)
                            ClassifierTaskSummary(controller: controller,
                                onEdit: { editing = false; showTaskEditor = true },
                                onSaved: { editing = false; showSavedTasks = true })
                        }
                        if case .failed(let message) = controller.phase {
                            Label { Text(odKey: message) } icon: { Image(systemName: "exclamationmark.circle") }
                                .font(.subheadline).foregroundStyle(ODPalette.red)
                                .accessibilityIdentifier("classifier.error")
                        }
                        if let result = controller.printedResult {
                            ClassifierResultActions(result: result, onInspect: { inspectedResult = result })
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, ODLayout.pageInset)
                    .padding(.bottom, ODLayout.groupGap)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: controller.printedResult?.id) { _, id in
                    if id != nil, workspaceVisible {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) {
                            scroll.scrollTo("classifier-stage", anchor: .top)
                        }
                    }
                }
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODWorkspaceBottomBar {
                    ClassifierActionBar(controller: controller, hasModels: !models.isEmpty,
                        onRun: { editing = false; onRun() }, onOpenModels: onOpenModels)
                }
            }
            .odNavigationTitle("Classifiers").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !sidebarPinned {
                    ToolbarItem(placement: .topBarLeading) { ODAppMenuButton(action: onOpenMenu) }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { editing = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Hide keyboard")
                    Spacer()
                }
            }
            .tint(ODPalette.text)
            .sheet(isPresented: $showSavedTasks) { SavedClassifierTasksSheet(controller: controller) }
            .sheet(isPresented: $showTaskEditor) { ClassifierTaskEditorSheet(controller: controller) }
            .sheet(item: $inspectedResult) { result in ClassifierResultDetailsSheet(result: result) }
            .onAppear { if controller.selectedModelID.isEmpty { controller.selectedModelID = models.first?.id ?? "" } }
            .onChange(of: models.map(\.id)) { _, ids in
                if !ids.contains(controller.selectedModelID) { controller.selectedModelID = ids.first ?? "" }
            }
            .onChange(of: workspaceVisible) { _, visible in if !visible { editing = false } }
            .onChange(of: controller.calibrated) { _, _ in controller.refreshValidation() }
            .onChange(of: controller.imageData) { _, _ in controller.refreshValidation() }
            .onChange(of: [controller.input, controller.instructions, controller.optionsText, controller.rubricText, controller.falseCriterion, controller.trueCriterion, controller.selectedModelID, controller.type.rawValue]) { _, _ in controller.refreshValidation() }
        }
    }
}

private struct ClassifierModelSummary: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    let models: [ClassifierModelInfo]
    let onActivate: () -> Void
    let onOpenModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            Text("On-device model").font(.caption.weight(.semibold)).foregroundStyle(ODPalette.secondary)
            if models.isEmpty {
                Text("Download a classifier from Models → Discover → Classifiers.")
                    .font(.subheadline).foregroundStyle(ODPalette.secondary)
            } else {
                Picker("Model", selection: $controller.selectedModelID) {
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu).labelsHidden().tint(ODPalette.text)
                .frame(minHeight: ODLayout.minimumHit, alignment: .leading)
                .disabled(controller.phase.busy).accessibilityIdentifier("classifier.model")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ODLayout.labelGap) {
                        ClassifierStatus(controller: controller)
                        Spacer(minLength: ODLayout.elementGap)
                        ClassifierModelAction(controller: controller, onActivate: onActivate)
                    }
                    VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                        ClassifierStatus(controller: controller)
                        ClassifierModelAction(controller: controller, onActivate: onActivate)
                    }
                }
            }
            Button("Find a model", systemImage: "shippingbox", action: onOpenModels)
                .font(.subheadline).frame(minHeight: ODLayout.minimumHit)
                .accessibilityIdentifier("classifier.findModel")
            Text("Activating a classifier releases the other active model. You can return to Assistant and reload it later.")
                .font(.footnote).foregroundStyle(ODPalette.secondary)
        }
    }
}

private struct ClassifierStatus: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    var body: some View {
        HStack(spacing: ODLayout.elementGap) {
            if controller.phase.busy { ProgressView().accessibilityHidden(true) }
            Label {
                Text(odKey: controller.isActiveSelection || controller.phase.busy ? controller.phase.title : "Not active")
            } icon: {
                Image(systemName: controller.isActiveSelection ? "checkmark.circle.fill" : "circle")
            }
                .font(.subheadline).foregroundStyle(ODPalette.secondary)
        }
        .accessibilityIdentifier("classifier.status")
    }
}

private struct ClassifierModelAction: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    let onActivate: () -> Void
    var body: some View {
        HStack(spacing: ODLayout.elementGap) {
            if !controller.isActiveSelection {
                Button("Activate model", action: onActivate)
                    .accessibilityIdentifier("classifier.activate")
            }
            if controller.activeModel != nil {
                Button("Unload model") { controller.unload() }
                    .accessibilityIdentifier("classifier.unload")
            }
        }
        .buttonStyle(.glass).controlSize(.regular)
        .disabled(controller.phase.busy || controller.selectedModelID.isEmpty)
    }
}

private struct ClassifierTextInput: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    let editing: FocusState<Bool>.Binding
    var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            Text("Input").font(.caption.weight(.semibold)).foregroundStyle(ODPalette.secondary)
            TextField("Paste or type text to classify", text: $controller.input, axis: .vertical)
                .lineLimit(4...10).font(.body).focused(editing)
                .padding(ODLayout.bubbleInsetH)
                .background(ODPalette.input, in: RoundedRectangle(cornerRadius: ODLayout.panelCorner))
                .accessibilityLabel("Text to classify").accessibilityIdentifier("classifier.input")
                .disabled(controller.phase.busy)
            if let message = controller.validationMessage {
                Text(odKey: message).font(.footnote).foregroundStyle(ODPalette.red)
                    .accessibilityIdentifier("classifier.validation")
            } else if let used = controller.usedTokens, let model = controller.activeModel {
                Text("\(used) of \(model.window) tokens used. Input stays on this device.")
                    .font(.footnote).foregroundStyle(ODPalette.secondary)
            } else {
                Text("Input stays on this device.").font(.footnote).foregroundStyle(ODPalette.secondary)
            }
        }
    }
}

private struct ClassifierTaskSummary: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    let onEdit: () -> Void
    let onSaved: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            Text("Task").font(.caption.weight(.semibold)).foregroundStyle(ODPalette.secondary)
            ClassifierTaskPicker(type: $controller.type)
            Button(action: onEdit) {
                HStack(spacing: ODLayout.labelGap) {
                    VStack(alignment: .leading, spacing: ODLayout.smallGap) {
                        Text("Instructions and categories").font(.subheadline.weight(.medium))
                        Text(controller.instructions).font(.subheadline).foregroundStyle(ODPalette.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ODPalette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: ODLayout.minimumHit, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("classifier.editTask")
            Button("Saved classifiers", systemImage: "bookmark", action: onSaved)
                .font(.subheadline).frame(minHeight: ODLayout.minimumHit)
                .accessibilityIdentifier("classifier.savedTasks")
        }
        .disabled(controller.phase.busy)
    }
}

private struct ClassifierActionBar: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    let hasModels: Bool
    let onRun: () -> Void
    let onOpenModels: () -> Void
    var body: some View {
        VStack(spacing: ODLayout.elementGap) {
            if hasModels && !controller.isActiveSelection && !controller.phase.busy {
                Text("Activate a model to start.").font(.footnote).foregroundStyle(ODPalette.secondary)
            }
            if controller.phase.busy {
                Button("Stop", role: .destructive) { controller.stop() }
                    .disabled(controller.phase == .stopping).accessibilityIdentifier("classifier.stop")
                    .buttonStyle(.glass).controlSize(.large).buttonBorderShape(.capsule)
            } else if !hasModels {
                Button("Find a model", systemImage: "shippingbox", action: onOpenModels)
                    .frame(maxWidth: .infinity).buttonStyle(.glassProminent).odInkProminent()
                    .accessibilityIdentifier("classifier.findModelPrimary")
            } else {
                Button(action: onRun) {
                    Label("Classify", systemImage: "checklist")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: ODLayout.groupGap)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large).odInkProminent()
                .disabled(!controller.isActiveSelection || !controller.hasInput || controller.validationMessage != nil)
                .accessibilityIdentifier("classifier.run")
            }
        }
        .frame(maxWidth: ODLayout.readableMaximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ODLayout.pageInset).padding(.top, ODLayout.elementGap).padding(.bottom, ODLayout.labelGap)
    }
}

private struct ClassifierResultActions: View {
    let result: ClassifierPrintedResult
    let onInspect: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            Button("Result details", systemImage: "doc.text.magnifyingglass", action: onInspect)
                .accessibilityIdentifier("classifier.details")
            ShareLink(item: ClassifierResultExport.json(result.answer, modelID: result.model.id,
                elapsedSeconds: result.elapsedSeconds)) { Label("Export result JSON", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("classifier.export")
        }
        .font(.subheadline).buttonStyle(.glass).controlSize(.regular)
    }
}

private struct ClassifierTaskEditorSheet: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    @State private var template: CoreAIClassifierWorkbench.Template = .custom
    @FocusState private var editing: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    Picker("Start from", selection: $template) {
                        ForEach(CoreAIClassifierWorkbench.Template.allCases) { Text(odKey: $0.title).tag($0) }
                    }.accessibilityIdentifier("classifier.template")
                    ClassifierTaskPicker(type: $controller.type)
                    TextField("What should the model decide?", text: $controller.instructions, axis: .vertical)
                        .lineLimit(2...6).focused($editing)
                        .accessibilityLabel("Classifier instructions").accessibilityIdentifier("classifier.instructions")
                }
                ClassifierQuestionSection(controller: controller, editing: $editing)
                if controller.activeModel?.supportsCalibration == true {
                    Section {
                        Toggle("Published calibration", isOn: $controller.calibrated)
                            .accessibilityIdentifier("classifier.calibration")
                    } footer: { Text("Use the publisher’s fitted probability calibration for this model.") }
                }
            }
            .disabled(controller.phase.busy)
            .scrollContentBackground(.hidden).background { ODPageBackground().ignoresSafeArea() }
            .odNavigationTitle("Instructions and categories").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { editing = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Hide keyboard")
                    Spacer()
                }
            }
            .tint(ODPalette.text)
            .onChange(of: template) { _, value in controller.apply(value) }
        }
    }
}

private struct ClassifierTaskPicker: View {
    @Binding var type: ClassifierRequest.Kind
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if typeSize.isAccessibilitySize {
            Picker("Decision", selection: $type) {
                ForEach(ClassifierRequest.Kind.allCases) { Text(odKey: $0.title).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("classifier.type")
        } else {
            Picker("Decision", selection: $type) {
                ForEach(ClassifierRequest.Kind.allCases) { Text(odKey: $0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("classifier.type")
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
    var isImage = false
    var elapsed: Double?
    var modelID: String?
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
            if let elapsed { LabeledContent("Run time") { Text("\(elapsed, format: .number.precision(.fractionLength(2))) s") } }
            ForEach(Array(zip(answer.optionIDs, answer.probabilities)).sorted { $0.1 > $1.1 }.prefix(isImage ? 10 : 20), id: \.0) { id, probability in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(id); Spacer(); Text(probability, format: .percent.precision(.fractionLength(1))).monospacedDigit() }
                    ProgressView(value: probability).tint(.primary)
                }
            }
            if isImage { Text("Top \(min(10, answer.optionIDs.count)) of \(answer.optionIDs.count) published image categories. Export includes every score.").font(.footnote).foregroundStyle(.secondary) }
            if let direct = answer.directAnswerProbability {
                LabeledContent("Direct-answer confidence") { Text(direct, format: .percent.precision(.fractionLength(1))) }
                Text("The model’s advisory estimate for answering directly. It does not start actions or tools.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ShareLink(item: ClassifierResultExport.json(answer, modelID: modelID, elapsedSeconds: elapsed)) { Label("Export result JSON", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("classifier.export")
        } header: { Text("Result") }
    }
}

private struct ClassifierResultDetailsSheet: View {
    let result: ClassifierPrintedResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ClassifierResultSection(answer: result.answer, type: result.type,
                    isImage: result.model.isImage, elapsed: result.elapsedSeconds, modelID: result.model.id)
            }
            .scrollContentBackground(.hidden).background { ODPageBackground().ignoresSafeArea() }
            .odNavigationTitle("Result details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ClassifierImageSection: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    @State private var photo: PhotosPickerItem?
    @State private var thumbnail: UIImage?
    @State private var importing = false
    @State private var errorMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            Text("Image").font(.caption.weight(.semibold)).foregroundStyle(ODPalette.secondary)
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: ODLayout.panelCorner))
                    .accessibilityLabel("Selected image to classify")
            }
            PhotosPicker(selection: $photo, matching: .images) { Label("Choose photo", systemImage: "photo") }
                .accessibilityIdentifier("classifier.choosePhoto")
            Button { importing = true } label: { Label("Choose image file", systemImage: "folder") }
                .accessibilityIdentifier("classifier.chooseImageFile")
            if controller.imageData != nil {
                Button("Remove image", role: .destructive) { controller.imageData = nil; photo = nil }
                    .accessibilityIdentifier("classifier.removeImage")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            Text("The model uses its fixed ImageNet categories. Your text draft and custom labels are kept when you switch back to a decision model. Images stay on this device.")
                .font(.footnote).foregroundStyle(ODPalette.secondary)
        }
        .buttonStyle(.glass).controlSize(.regular)
        .disabled(controller.phase.busy)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try select(handle.read(upToCount: 20 * 1_024 * 1_024 + 1) ?? Data())
            } catch { errorMessage = error.localizedDescription }
        }
        .task(id: photo) {
            guard let photo else { return }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw CoreAIInferenceError.invalidImage("Couldn’t read this photo.") }
                try Task.checkCancellation(); try select(data)
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
        .onAppear { updateThumbnail() }
        .onChange(of: controller.imageData) { _, _ in updateThumbnail() }
    }
    private func select(_ data: Data) throws {
        guard !controller.phase.busy, !data.isEmpty, data.count <= 20 * 1_024 * 1_024,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else { throw CoreAIInferenceError.invalidImage("Choose a valid image under 20 MB.") }
        controller.imageData = data; errorMessage = nil
    }
    private func updateThumbnail() {
        thumbnail = nil
        guard let data = controller.imageData, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) else { return }
        thumbnail = UIImage(cgImage: image)
    }
}

private struct SavedClassifierTasksSheet: View {
    @ObservedObject var controller: CoreAIClassifierWorkbench
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var naming: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name this classifier", text: $name).focused($naming).accessibilityIdentifier("classifier.savedName")
                    Button("Save current task") {
                        do { try controller.saveTask(named: name); name = ""; errorMessage = nil }
                        catch { errorMessage = error.localizedDescription }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("classifier.saveTask")
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                } footer: { Text("Saves the instructions and labels on this device. Input text and photos are kept out of the saved task.") }
                Section("Your classifiers") {
                    if controller.savedTasks.isEmpty { Text("Save a task to reuse it with another input or model.").foregroundStyle(.secondary) }
                    ForEach(controller.savedTasks) { task in
                        Button { controller.apply(task); dismiss() } label: {
                            VStack(alignment: .leading) { Text(task.name); Text(task.type.title).font(.caption).foregroundStyle(.secondary) }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { try? controller.deleteTask(id: task.id) } }
                    }
                }
            }
            .scrollContentBackground(.hidden).background { ODPageBackground().ignoresSafeArea() }
            .odNavigationTitle("Saved classifiers").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { naming = false } label: { Image(systemName: "keyboard.chevron.compact.down") }.accessibilityLabel("Hide keyboard")
                    Spacer()
                }
            }
        }
    }
}
