import SwiftUI
import OnDeviceUI

/// Current native Image studio composition over the existing generation service.
struct ImageGenerationView: View {
    var onOpenMenu: (() -> Void)? = nil
    @ObservedObject private var service = ImageGenerationService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    @FocusState private var promptFocused: Bool
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var steps: Double = 0
    @State private var showsModels = false
    @State private var showsOptions = false
    @State private var deletingModel: ImageGenerationService.Model?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ODLayout.groupGap) {
                    if let image = service.image {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: ODLayout.corner))
                            .accessibilityLabel("Generated image")
                            // Each finished image is its own view, so it fades in
                            // rather than snapping over the previous result.
                            .id(service.resultURL)
                            .transition(.opacity.combined(with: .scale(0.98)))
                        if let resultPrompt = service.resultPrompt {
                            Text(resultPrompt).font(.body).textSelection(.enabled)
                                .accessibilityIdentifier("image.result.prompt")
                        }
                    } else {
                        emptyCanvas
                        ODImagePromptSuggestions(prompt: $prompt) { promptFocused = true }
                            .disabled(service.isWorking)
                    }
                    if service.isWorking {
                        Text(service.statusMessage.isEmpty ? "Preparing image" : service.statusMessage)
                            .font(.footnote).foregroundStyle(.secondary)
                            .odShimmer()
                            .transition(.opacity)
                    }
                    if case .failed(let message) = service.state {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .animation(ODMotion.fade, value: service.isWorking)
                .animation(ODMotion.resolve(ODMotion.standard, reduceMotion: reduceMotion), value: service.resultURL)
                .padding(ODLayout.pageInset)
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { ODWorkspaceBottomBar { nextImageDock } }
            .navigationTitle("Image studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onOpenMenu {
                    ToolbarItem(placement: .topBarLeading) {
                        ODAppMenuButton(action: onOpenMenu).accessibilityIdentifier("navigation.menu")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let image = service.image, let url = service.resultURL {
                        ShareLink(item: url, preview: SharePreview("Generated image", image: Image(uiImage: image))) {
                            Label("Share image", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    ODKeyboardDismissKey(focus: $promptFocused)
                    Spacer(minLength: 0)
                }
            }
            .sheet(isPresented: $showsModels) { modelPicker }
            .sheet(isPresented: $showsOptions) { options }
        }
    }

    /// A compact marker for the result slot before the first generation. It
    /// pre-teaches where output lands without dominating the writing area.
    private var emptyCanvas: some View {
        HStack(spacing: ODLayout.labelGap) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3.weight(.light))
            Text("Your image will appear here")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(
            RoundedRectangle(cornerRadius: ODLayout.corner, style: .continuous)
                .fill(ODPalette.text.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ODLayout.corner, style: .continuous)
                .strokeBorder(ODPalette.text.opacity(0.10), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No image yet. Your image will appear here.")
    }

    private var nextImageDock: some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            TextField("Describe an image", text: $prompt, axis: .vertical)
                .font(.body).lineLimit(1...6).submitLabel(.return)
                .focused($promptFocused)
                .padding(.vertical, 4)
                .accessibilityIdentifier("image.draft.prompt")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ODLayout.elementGap) { modelActionLabel; Spacer(minLength: 8); createButton }
                VStack(alignment: .leading, spacing: ODLayout.elementGap) { modelActionLabel; createButton }
            }
        }
        .padding(ODLayout.panelHorizontalInset)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ODLayout.panelCorner))
        .padding(.horizontal, ODLayout.pageInset)
        .padding(.vertical, ODLayout.elementGap)
        .background { ODPageBackground().ignoresSafeArea() }
    }

    @ViewBuilder private var modelActionLabel: some View {
        if !service.isInstalled(service.selectedModel) && !service.isWorking {
            Text("Image model required").font(.subheadline).foregroundStyle(.secondary)
        } else { modelMenu }
    }

    private var modelMenu: some View {
        Menu {
            Button { showsModels = true } label: {
                Label("Image model", systemImage: "cube")
                Text(service.selectedModel.displayName)
            }
            Button { showsOptions = true } label: {
                Label("Generation options", systemImage: "slider.horizontal.3")
                Text(steps < 1 ? "Model default steps" : "\(Int(steps)) steps")
            }
        } label: {
            ODModelMenuLabel(displayName: service.selectedModel.displayName)
                .frame(minHeight: ODLayout.minimumHit)
        }
        .menuOrder(.fixed)
        .disabled(service.isWorking)
        .accessibilityIdentifier("image.model")
    }

    private var generationFailed: Bool { if case .failed = service.state { return true }; return false }

    private var createButton: some View {
        Button(service.isCancelling ? "Stopping" : service.isWorking ? "Cancel" : !service.isInstalled(service.selectedModel) ? "Choose model" : generationFailed ? "Retry" : "Create", systemImage: service.isWorking ? "stop.fill" : !service.isInstalled(service.selectedModel) ? "cube" : generationFailed ? "arrow.clockwise" : "arrow.up") {
            if service.isWorking { service.cancel() }
            else if !service.isInstalled(service.selectedModel) { showsModels = true }
            else {
                // The service snapshots model, prompt and options before any asynchronous work.
                ODBridge.shared.store.requestExclusiveOperation("Creating an image") {
                    service.generate(prompt: prompt, negativePrompt: negativePrompt, steps: steps < 1 ? nil : Int(steps))
                }
                promptFocused = false
            }
        }
        .buttonStyle(.glassProminent).odInkProminent()
        .controlSize(.large)
        .disabled(service.isCancelling || (!service.isWorking && service.isInstalled(service.selectedModel) && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    private var modelPicker: some View {
        NavigationStack {
            List {
                ForEach(ImageGenerationService.catalog) { model in
                    Section {
                        Button {
                            service.select(model.id)
                            showsModels = false
                        } label: {
                            HStack(alignment: .top, spacing: ODLayout.labelGap) {
                                VStack(alignment: .leading, spacing: ODLayout.unit) {
                                    Text(model.displayName).font(.body).foregroundStyle(ODPalette.text)
                                    Text(model.subtitle).font(.footnote).foregroundStyle(.secondary)
                                    Text(model.sizeLabel).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if model.id == service.selectedModelID { Image(systemName: "checkmark").foregroundStyle(ODPalette.text) }
                            }
                        }
                        if service.isInstalled(model) {
                            Button("Delete model", role: .destructive) { deletingModel = model }
                        } else if service.isDownloading(model) {
                            ProgressView(value: service.downloadProgress(for: model))
                        } else {
                            Button("Download model", systemImage: "arrow.down.circle") { service.startDownload(model) }
                        }
                        if let error = service.directDownloadErrors[model.id] {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Image models")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsModels = false } } }
            .confirmationDialog("Delete image model?", isPresented: Binding(get: { deletingModel != nil }, set: { if !$0 { deletingModel = nil } })) {
                Button("Delete", role: .destructive) {
                    if let model = deletingModel { service.deleteModel(model) }
                    deletingModel = nil
                }
            }
        }
    }

    private var options: some View {
        NavigationStack {
            Form {
                if service.selectedModel.supportsNegativePrompt {
                    Section("Avoid in the image") {
                        TextField("Negative prompt", text: $negativePrompt, axis: .vertical).lineLimit(1...6)
                    }
                }
                Section("Generation steps") {
                    LabeledContent("Steps", value: steps < 1 ? "Model default" : String(Int(steps)))
                    Slider(value: $steps, in: 0...50, step: 1)
                    Text("More steps take longer. Turbo models usually need only a few.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Generation options")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsOptions = false } } }
        }
    }
}
