import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// A result canvas with a compact native creation dock. The host owns image inference.
@MainActor
struct ODImageStudioView: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    @FocusState private var promptFocused: Bool
    @State private var modelPickerPresented = false

    private var canGenerate: Bool {
        store.selectedImageModel != nil && store.canPerformActions && store.capabilities.canGenerateImages
        && !store.imagePhase.isGenerating
        && !store.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: ODLayout.labelGap) {
                        if let resultURL = store.imageResultURL {
                            ODGeneratedResultView(url: resultURL)
                            if let prompt = store.imageResultPrompt, !prompt.isEmpty {
                                Text(prompt)
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if store.imagePhase.isGenerating {
                                Text("Previous result").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            ODImagePromptSuggestions(prompt: $store.imagePrompt) { promptFocused = true }
                                .disabled(store.imagePhase.isGenerating)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ODLayout.pageInset)
                }
                .scrollDismissesKeyboard(.interactively)
            .background { ODPageBackground().ignoresSafeArea() }
            .safeAreaInset(edge: .bottom, spacing: 0) { ODWorkspaceBottomBar { creationDock } }
            .navigationTitle("Image studio")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton { store.conversationsPresented = true }
                        .accessibilityIdentifier("navigation.menu")
                }
                if let resultURL = store.imageResultURL {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: resultURL) {
                            Label("Share image", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $modelPickerPresented) { imageModelPicker }
        }
    }

    private var creationDock: some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            TextField("Describe the image", text: $store.imagePrompt, axis: .vertical)
                .font(.body).foregroundStyle(ODPalette.text)
                .tint(ODPalette.text)
                .lineLimit(1...5)
                .frame(minHeight: ODLayout.minimumHit, alignment: .topLeading)
                .focused($promptFocused)
                .disabled(store.imagePhase.isGenerating)
                .accessibilityLabel("Image prompt")
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                    modelChoice
                    createControl
                }
            } else {
                HStack(spacing: ODLayout.labelGap) {
                    modelChoice
                    Spacer(minLength: 0)
                    createControl
                }
            }
            generationStatus
            if store.selectedImageModel == nil && !store.imagePhase.isGenerating {
                Text("Select an image model to create.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(ODLayout.panelHorizontalInset)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ODLayout.panelCorner))
        .padding(.horizontal, ODLayout.pageInset)
        .padding(.vertical, ODLayout.elementGap)
        .background { ODPageBackground().ignoresSafeArea() }
    }

    private var modelChoice: some View {
        Button {
            promptFocused = false
            modelPickerPresented = true
        } label: {
            HStack(spacing: ODLayout.elementGap) {
                Image(systemName: "cube")
                Text(store.selectedImageModel?.name ?? "Choose model")
                    .lineLimit(dynamicType.isAccessibilitySize ? nil : 1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(store.imagePhase.isGenerating)
        .accessibilityLabel("Image model: \(store.selectedImageModel?.name ?? "None selected")")
        .accessibilityHint("Choose an installed image model")
    }

    @ViewBuilder private var createControl: some View {
        if store.imagePhase.isGenerating {
            if store.capabilities.canCancelImageGeneration {
                Button("Cancel") { store.send(.cancelImageGeneration) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(!store.canPerformActions)
            }
        } else if store.selectedImageModel == nil {
            Button("Choose model") { modelPickerPresented = true }
                .buttonStyle(.glassProminent).tint(.blue)
                .controlSize(.large)
        } else {
            Button("Create", action: generate)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.blue)
                .disabled(!canGenerate)
        }
    }

    @ViewBuilder private var generationStatus: some View {
        switch store.imagePhase {
        case .generating(let step):
            HStack(spacing: ODLayout.elementGap) {
                ProgressView().accessibilityHidden(true)
                Text(step.isEmpty ? "Generating…" : step)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            if store.selectedImageModel != nil && (!store.canPerformActions || !store.capabilities.canGenerateImages) {
                Text("Image generation is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var imageModelPicker: some View {
        NavigationStack {
            List {
                if store.imageModels.isEmpty {
                    Section {
                        Text("No image models installed").font(.headline)
                        Text("Add an image model from your catalog to use it here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Browse image models", systemImage: "cube") { store.send(.openImageModelPicker) }
                            .disabled(!store.canPerformActions)
                    }
                } else {
                    Section("Installed") {
                        ForEach(store.imageModels) { model in
                            Button {
                                store.selectedImageModelID = model.id
                                modelPickerPresented = false
                            } label: {
                                HStack(spacing: ODLayout.labelGap) {
                                    VStack(alignment: .leading, spacing: ODLayout.unit) {
                                        Text(model.name).foregroundStyle(ODPalette.text)
                                        if !model.metadata.isEmpty {
                                            Text(model.metadata).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if model.id == store.selectedImageModelID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .frame(minHeight: ODLayout.minimumHit)
                                .contentShape(Rectangle())
                            }
                            .accessibilityAddTraits(model.id == store.selectedImageModelID ? .isSelected : [])
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Image models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { modelPickerPresented = false }
                }
            }
        }
    }

    private func generate() {
        guard canGenerate, let model = store.selectedImageModel else { return }
        promptFocused = false
        store.send(.generateImage(prompt: store.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines), modelID: model.id))
    }
}

/// Results are supplied by the host. Missing files produce an explicit recoverable display state.
private struct ODGeneratedResultView: View {
    let url: URL

    var body: some View {
        Group {
            if url.isFileURL {
                ODLocalGeneratedImage(url: url)
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().frame(maxWidth: .infinity, minHeight: 45 * ODLayout.unit)
                    case .success(let image):
                        image.resizable().scaledToFit().accessibilityLabel("Generated image")
                    case .failure:
                        unavailable
                    @unknown default:
                        unavailable
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: ODLayout.corner))
    }

    private var unavailable: some View {
        Label("This image could not be opened.", systemImage: "exclamationmark.circle")
            .font(.subheadline).foregroundStyle(ODPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 45 * ODLayout.unit)
    }
}

/// Decode only when the URL changes. Disk I/O and thumbnail creation stay off the main actor.
/// Hosts should publish a distinct file URL for each generated result.
@MainActor
private struct ODLocalGeneratedImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("Generated image")
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 45 * ODLayout.unit)
                    .accessibilityLabel("Loading generated image")
            } else {
                Label("This image could not be opened.", systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(ODPalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 45 * ODLayout.unit)
            }
        }
        .task(id: url) {
            image = nil
            isLoading = true
            let imageURL = url
            let data = await Task.detached(priority: .userInitiated) {
                ODImageFileLoader.previewData(url: imageURL)
            }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap { UIImage(data: $0) }
            isLoading = false
        }
    }
}

private enum ODImageFileLoader {
    static func previewData(url: URL) -> Data? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }
}


/// Real editable examples shared by the production image screen and package host.
public struct ODImagePromptSuggestions: View {
    @Binding private var prompt: String
    private let onSelect: () -> Void
    @State private var pendingExample: String?
    private let labels = ["Lakeside cabin", "Ceramic still life", "Botanical sketch"]
    private let examples = ["A quiet lakeside cabin at sunrise, soft watercolor", "A ceramic teapot on linen, natural window light", "A small botanical garden, detailed pencil illustration"]
    public init(prompt: Binding<String>, onSelect: @escaping () -> Void = {}) {
        self._prompt = prompt
        self.onSelect = onSelect
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.labelGap) {
            Text("Create an image with a local model. Try one of these prompts, then edit it before creating.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal) {
                HStack(spacing: ODLayout.elementGap) {
                    ForEach(Array(examples.enumerated()), id: \.offset) { index, example in
                        Button {
                            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt != example {
                                pendingExample = example
                            } else { prompt = example; onSelect() }
                        } label: {
                            Text(labels[index])
                                .font(.subheadline)
                                .padding(.horizontal, ODLayout.labelGap)
                                .frame(minHeight: 36)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ODPalette.text)
                        .background(ODPalette.text.opacity(0.06), in: Capsule())
                        .accessibilityHint("Inserts editable text without creating an image")
                    }
                }
                .padding(.vertical, ODLayout.unit)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
        .padding(.vertical, ODLayout.elementGap)
        .alert("Replace your image prompt?", isPresented: Binding(get: { pendingExample != nil }, set: { if !$0 { pendingExample = nil } })) {
            Button("Replace prompt") {
                if let example = pendingExample { prompt = example; onSelect() }
                pendingExample = nil
            }
            Button("Keep draft", role: .cancel) { pendingExample = nil }
        }
    }
}
