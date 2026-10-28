import SwiftUI

@MainActor
struct ODModelDetailView: View {
    let modelID: String
    let performAfterDismiss: (ODAction) -> Void
    @EnvironmentObject private var store: ODStore
    @Environment(\.dismiss) private var dismiss
    @State private var deletionPresented = false

    private var model: ODModel? { store.models.first { $0.id == modelID } }
    private var canLoad: Bool {
        guard let model else { return false }
        return model.isInstalled && model.isSelectable && store.canPerformActions && store.capabilities.canLoadModels
            && !store.modelPhase.isPreparing && !store.isResponding
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let model {
                    VStack(alignment: .leading, spacing: ODLayout.groupGap) {
                        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                            Image(systemName: model.kind.symbol)
                                .font(.largeTitle.weight(.light))
                                .foregroundStyle(ODPalette.secondary)
                                .accessibilityHidden(true)
                            Text(model.name)
                                .font(.largeTitle.weight(.semibold))
                                .foregroundStyle(ODPalette.text)
                                .accessibilityAddTraits(.isHeader)
                            if !model.metadata.isEmpty {
                                Text(model.metadata).font(.body).foregroundStyle(ODPalette.secondary)
                            }
                            if model.isDefault {
                                Text("Default \(model.kind.title.lowercased()) model", bundle: .module)
                                    .font(.caption).foregroundStyle(ODPalette.secondary)
                            }
                        }
                        stateSection(model)
                        VStack(spacing: 0) {
                            ODDetailRow(title: "Capability", value: model.workspaceLabel)
                            ODDetailRow(title: "Download size", value: model.sizeLabel ?? "Not measured")
                            ODDetailRow(title: "Estimated runtime memory", value: model.estimatedMemoryBytes.map(ODFormat.bytes) ?? "Not provided")
                            ODDetailRow(title: "Availability", value: model.isInstalled ? "Installed" : "Not installed")
                        }
                        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                            ODSectionHeader("Source identifier")
                            Text(model.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(ODPalette.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Download size measures storage. Runtime memory varies with context and workload; the app checks availability before loading.", bundle: .module)
                            .font(.footnote).foregroundStyle(.secondary)
                        availableActions(model)
                    }
                    .padding(ODLayout.pageInset)
                } else {
                    ContentUnavailableView(ODLocalizedString("Model unavailable"), systemImage: "cube",
                                           description: Text("This model is no longer in your library.", bundle: .module))
                        .padding(.top, ODLayout.pageInset * 2)
                }
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .odNavigationTitle("Model details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ODLocalizedString("Done")) { dismiss() }.tint(ODPalette.text)
                }
            }
            .confirmationDialog(ODLocalizedString("Delete this model?"), isPresented: $deletionPresented, titleVisibility: .visible) {
                if let model {
                    Button(ODLocalizedString("Delete \(model.name)"), role: .destructive) {
                        performAfterDismiss(.modelAction(modelID: model.id, command: .delete))
                    }
                }
                Button(ODLocalizedString("Cancel"), role: .cancel) {}
            } message: {
                Text("Remove \(model?.name ?? "this model") from your device?", bundle: .module)
            }
        }
        .tint(ODPalette.text)
    }

    @ViewBuilder private func stateSection(_ model: ODModel) -> some View {
        if !model.isInstalled, let reason = model.unavailableReason {
            Text(odKey: reason).font(.subheadline).foregroundStyle(ODPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isInstalled && model.kind == .classifier {
            VStack(alignment: .leading, spacing: ODLayout.labelGap) {
                Label(ODLocalizedString("Installed for typed decisions"), systemImage: "checklist")
                    .font(.headline)
                Text("Choose options, score against a rubric, or ask a yes/no question in the Classifiers workspace.", bundle: .module)
                    .font(.subheadline).foregroundStyle(ODPalette.secondary)
                ODPrimaryButton("Use classifier", symbol: "checklist") {
                    performAfterDismiss(.loadModelInWorkspace(model.id, .classifier))
                }.disabled(!store.canPerformActions)
                ODPrimaryButton("Manage Core AI pack", symbol: "cpu") {
                    performAfterDismiss(.openCoreAIPacks)
                }
            }
        } else if model.isInstalled && !model.isSelectable {
            VStack(alignment: .leading, spacing: ODLayout.labelGap) {
                if let reason = model.unavailableReason {
                    Label(ODLocalizedString("Installed, but unavailable"), systemImage: "exclamationmark.circle")
                        .font(.headline).foregroundStyle(ODPalette.text)
                    Text(odKey: reason)
                        .font(.subheadline).foregroundStyle(ODPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Installed on this device", bundle: .module)
                        .font(.subheadline).foregroundStyle(ODPalette.secondary)
                    ODPrimaryButton("Manage Core AI pack", symbol: "cpu") {
                        performAfterDismiss(.openCoreAIPacks)
                    }
                }
            }
        } else if let status = model.downloadStatus {
            VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                Text(odKey: status).font(.headline)
                if let detail = model.downloadDetail {
                    Text(detail).font(.subheadline).foregroundStyle(ODPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status != "Download failed" {
                    ProgressView(value: model.downloadProgress)
                        .accessibilityLabel(Text(odKey: model.downloadDetail == nil ? "Model download progress" : "Model preparation progress"))
                }
                if model.isDownloadPaused || status == "Download failed" {
                    ODPrimaryButton(model.downloadDetail == nil ? "Resume download" : "Resume preparation", symbol: "arrow.clockwise") {
                        performAfterDismiss(.modelAction(modelID: model.id, command: .download))
                    }
                }
            }
        } else {
        switch store.phase(for: model) {
        case .preparing(let step):
            VStack(alignment: .leading, spacing: ODLayout.labelGap) {
                HStack(spacing: ODLayout.elementGap) {
                    ProgressView().tint(ODPalette.text).accessibilityHidden(true)
                    Text("Preparing model", bundle: .module).font(.headline).foregroundStyle(ODPalette.text)
                }
                Text(odKey: step.isEmpty ? "Getting the model ready to use." : step)
                    .font(.subheadline).foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, ODLayout.bubbleInsetV)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(alignment: .leading, spacing: ODLayout.labelGap) {
                Label(ODLocalizedString("The model couldn’t load"), systemImage: "exclamationmark.circle")
                    .font(.headline).foregroundStyle(ODPalette.text)
                Text(odKey: message)
                    .font(.subheadline).foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ODPrimaryButton("Try again", symbol: "arrow.clockwise") { performAfterDismiss(.loadModel(model.id)) }
                    .disabled(!canLoad)
            }
        case .ready:
            VStack(alignment: .leading, spacing: ODLayout.labelGap) {
                Label(ODLocalizedString("Loaded"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(ODPalette.secondary)
                if model.supportedKinds.contains(.language)
                    && model.supportedKinds.contains(.vision) {
                    useInBothWorkspaces(model)
                } else if model.id == store.selectedModelID {
                    ODPrimaryButton(destinationTitle(model), symbol: destinationSymbol(model)) {
                        openDestination(model)
                    }
                } else {
                    ODPrimaryButton("Use model", symbol: "arrow.right") { performAfterDismiss(.loadModel(model.id)) }
                        .disabled(!canLoad)
                }
            }
        case .unloaded:
            VStack(alignment: .leading, spacing: ODLayout.labelGap) {
                Text(odKey: model.isInstalled ? "Load this model when you’re ready to use it." : "Install this model from your catalog to use it on this device.")
                    .font(.subheadline).foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isInstalled {
                    if model.supportedKinds.contains(.language)
                        && model.supportedKinds.contains(.vision) {
                        useInBothWorkspaces(model)
                    } else {
                        ODPrimaryButton(model.kind == .language ? "Load model" : "Select model", symbol: "arrow.up.circle") { performAfterDismiss(.loadModel(model.id)) }
                            .disabled(!canLoad)
                    }
                    if !store.canPerformActions || !store.capabilities.canLoadModels {
                        Text("Model loading is currently unavailable.", bundle: .module)
                            .font(.caption).foregroundStyle(ODPalette.secondary)
                    }
                } else {
                    if (model.availableCommands ?? []).contains(.download) {
                        ODPrimaryButton("Download model", symbol: "arrow.down.circle") {
                            performAfterDismiss(.modelAction(modelID: model.id, command: .download))
                        }
                        .disabled(!store.canPerformActions)
                    } else {
                        Text("This model is not available for download.", bundle: .module)
                            .font(.footnote).foregroundStyle(ODPalette.secondary)
                    }
                }
            }
        }
        }
    }

    @ViewBuilder private func useInBothWorkspaces(_ model: ODModel) -> some View {
        ODPrimaryButton("Use in Assistant", symbol: "bubble.left") {
            performAfterDismiss(.loadModelInWorkspace(model.id, .language))
        }
        .disabled(!canLoad)
        ODPrimaryButton("Use in Lens", symbol: "camera") {
            performAfterDismiss(.loadModelInWorkspace(model.id, .vision))
        }
        .disabled(!canLoad)
    }

    @ViewBuilder private func availableActions(_ model: ODModel) -> some View {
        let commands = (model.availableCommands ?? store.capabilities.modelCommands)
            .filter { model.isInstalled && [.configure, .export, .delete].contains($0) }
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ODSectionHeader("Manage model")
                    .padding(.bottom, ODLayout.elementGap)
                ForEach(commands) { command in
                    if command == .delete {
                        Button(role: .destructive) { deletionPresented = true } label: {
                            Label(ODLocalizedString("Delete model"), systemImage: "trash")
                                .font(.body).foregroundStyle(ODPalette.red)
                                .frame(maxWidth: .infinity, minHeight: ODLayout.rowMinimumHeight, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ODPressButtonStyle())
                        .disabled(!store.canPerformActions || !model.isInstalled
                                  || store.phase(for: model).isPreparing || store.isResponding)
                        .accessibilityIdentifier("model.delete.\(model.id)")
                    } else {
                        Button { performAfterDismiss(.modelAction(modelID: model.id, command: command)) } label: {
                            ODWorkspaceLinkLabel(title: command.title, symbol: command == .export ? "square.and.arrow.up" : "slider.horizontal.3")
                        }
                        .buttonStyle(ODPressButtonStyle())
                        .disabled(!store.canPerformActions || store.phase(for: model).isPreparing
                                  || store.isResponding || (command == .export && !model.isInstalled))
                    }
                    ODHairline()
                }
            }
        }
    }

    private func destinationTitle(_ model: ODModel) -> String {
        switch model.kind {
        case .language: return "Open Chat"
        case .vision: return "Open Lens"
        case .voice: return "Open Voice"
        case .image: return "Select for Image studio"
        case .utility, .classifier: return "Manage pack"
        }
    }
    private func destinationSymbol(_ model: ODModel) -> String {
        switch model.kind {
        case .language: return "bubble.left"
        case .vision: return "camera"
        case .voice: return "waveform"
        case .image: return "checkmark"
        case .utility, .classifier: return "cpu"
        }
    }
    private func openDestination(_ model: ODModel) {
        switch model.kind {
        case .language: store.selectedTab = .chat
        case .vision: store.selectedTab = .lens
        case .voice: store.selectedTab = .voice
        case .image:
            performAfterDismiss(.loadModel(model.id))
            return
        case .utility, .classifier:
            performAfterDismiss(.openCoreAIPacks)
            return
        }
        if model.kind != .image { store.secondaryRoute = nil }
        dismiss()
    }
}

/// Metrics stay readable at accessibility sizes and never substitute zero for unknown data.
struct ODDetailRow: View {
    let title: String
    let value: String
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                    Text(odKey: title).foregroundStyle(ODPalette.secondary)
                    Text(value).foregroundStyle(ODPalette.text).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: ODLayout.labelGap) {
                    Text(odKey: title).foregroundStyle(ODPalette.secondary)
                    Spacer(minLength: 0)
                    Text(value)
                        .foregroundStyle(ODPalette.text)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, ODLayout.bubbleInsetV)
        .overlay(alignment: .bottom) { ODHairline() }
        .accessibilityElement(children: .combine)
    }
}
