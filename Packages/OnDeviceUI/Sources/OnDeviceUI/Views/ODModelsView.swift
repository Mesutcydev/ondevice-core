import SwiftUI

/// The one place to browse, import, select, and manage models.
@MainActor
struct ODModelsView: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.odSidebarPinned) private var sidebarPinned
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var scope: ODModelScope = .installed
    @State private var kind: ODModelKind?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var detailModel: ODModel?
    @State private var useDestinationModel: ODModel?
    @State private var showsUseDestinations = false
    @State private var deferredModelAction: ODAction?
    @Namespace private var modelZoom

    private var installedCount: Int { store.models.filter { $0.isInstalled && $0.isLibraryEntry }.count }
    private var transferCount: Int { store.models.filter { $0.downloadStatus != nil }.count }
    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showsCoreAIPacks: Bool {
        guard scope == .discover, kind == nil else { return false }
        return trimmedQuery.isEmpty || "Core AI packs".localizedCaseInsensitiveContains(trimmedQuery)
    }
    private var filteredModels: [ODModel] {
        var seen = Set<String>()
        let matches = store.models.filter { model in
            model.isLibraryEntry && (scope == .installed ? model.isInstalled : !model.isInstalled)
            && (kind.map {
                // Show blocked packs under every declared role. For a pack
                // with a usable role, keep unsupported roles out of "Use".
                (model.isSelectable ? model.supportedKinds : model.declaredKinds).contains($0)
            } ?? true)
            && (trimmedQuery.isEmpty || "\(model.name) \(model.metadata) \(model.id) \(model.workspaceLabel) \(model.summary ?? "")".localizedCaseInsensitiveContains(trimmedQuery))
            && seen.insert(model.id).inserted
        }
        guard scope == .installed else { return matches }
        return matches.sorted { lhs, rhs in
            if (lhs.id == store.selectedModelID) != (rhs.id == store.selectedModelID) {
                return lhs.id == store.selectedModelID
            }
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modelActions
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(ODLocalizedString("Model library"), selection: $scope) {
                            ForEach(ODModelScope.allCases) { option in
                                Text(odKey: option.title).tag(option).accessibilityIdentifier("models.scope.\(option.rawValue)")
                            }
                        }
                        .pickerStyle(.segmented).accessibilityIdentifier("models.scope")
                        ODCapabilityChips(kind: $kind)
                            .onChange(of: kind) { _, selected in
                                // A new classifier has no installed row yet. Show
                                // its catalog rather than landing on an empty page.
                                if selected == .classifier && scope == .installed
                                    && !store.models.contains(where: { $0.isInstalled && $0.declaredKinds.contains(.classifier) }) {
                                    scope = .discover
                                }
                            }
                    }

                    if scope == .discover && trimmedQuery.isEmpty {
                        Button { store.send(.openDiscovery) } label: {
                            ODLibraryRow(title: "Search Hugging Face", detail: "Find a model beyond the curated list",
                                         symbol: "magnifyingglass")
                        }
                        .buttonStyle(ODPressButtonStyle())
                        .disabled(!store.canPerformActions)
                        .accessibilityIdentifier("models.searchHub")
                    }

                    if showsCoreAIPacks {
                        Button { store.send(.openCoreAIPacks) } label: {
                            ODLibraryRow(title: "Browse Core AI packs", detail: "Find on-device models for iOS 27",
                                         symbol: "cpu")
                        }
                        .buttonStyle(ODPressButtonStyle())
                        .disabled(!store.canPerformActions)
                        .accessibilityHint(Text("Opens the on-device model pack catalog", bundle: .module))
                        .accessibilityIdentifier("models.corePacks")
                    }

                    if filteredModels.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(odKey: scope == .installed ? "Downloaded" : "Available to download")
                                    .font(.headline).foregroundStyle(ODPalette.text)
                                    .accessibilityAddTraits(.isHeader)
                                Spacer()
                                Text(filteredModels.count, format: .number)
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(ODPalette.secondary)
                            }
                            .padding(.horizontal, 4)
                            ForEach(filteredModels) { model in
                                ODModelCard(
                                    model: model,
                                    phase: store.phase(for: model),
                                    isSelected: model.id == store.selectedModelID,
                                    canPerformActions: store.canPerformActions,
                                    showsDownload: showsDownloadAction(model),
                                    onDetails: { detailModel = model },
                                    onUse: { use(model) },
                                    onDownload: { store.send(.modelAction(modelID: model.id, command: .download)) },
                                    onPause: { store.send(.modelAction(modelID: model.id, command: .pauseDownload)) },
                                    onCancel: { store.send(.modelAction(modelID: model.id, command: .cancelDownload)) }
                                )
                                .matchedTransitionSource(id: model.id, in: modelZoom)
                                .transition(.opacity)
                            }
                        }
                    }

                    if scope == .installed && trimmedQuery.isEmpty {
                        Button { store.send(.manageStorage) } label: {
                            ODLibraryRow(title: "Manage model storage",
                                         detail: "\(installedCount) on device · \(store.metrics.modelStorageBytes.map { "\(ODFormat.bytes($0)) used" } ?? "Storage not measured")",
                                         symbol: "internaldrive")
                        }
                        .buttonStyle(ODPressButtonStyle())
                        .accessibilityIdentifier("models.storage")
                    }
                }
                .animation(ODMotion.resolve(ODMotion.standard, reduceMotion: reduceMotion), value: scope)
                .animation(ODMotion.resolve(ODMotion.standard, reduceMotion: reduceMotion), value: kind)
                .padding(.horizontal, ODLayout.pageInset)
                .padding(.top, 12)
                .padding(.bottom, ODLayout.groupGap)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search models", bundle: .module))
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { searchFocused = false }
            .onChange(of: store.conversationsPresented) { _, open in
                if open { searchFocused = false }
            }
            .onChange(of: store.selectedTab) { _, destination in
                if destination != .models { searchFocused = false }
            }
            .scrollDismissesKeyboard(.interactively)
            .odNavigationTitle("Models")
            .toolbar {
                if !sidebarPinned {
                    ToolbarItem(placement: .topBarLeading) {
                        ODAppMenuButton { store.conversationsPresented = true }
                            .labelStyle(.iconOnly)
                        .accessibilityIdentifier("navigation.menu")
                    }
                }
            }
            .sheet(item: $detailModel, onDismiss: {
                if let action = deferredModelAction {
                    deferredModelAction = nil
                    store.send(action)
                }
            }) { model in
                ODModelDetailView(modelID: model.id) { action in
                    deferredModelAction = action
                    detailModel = nil
                }
                .environmentObject(store)
                .navigationTransition(.zoom(sourceID: model.id, in: modelZoom))
            }
            .confirmationDialog(
                ODLocalizedString("Use model in"),
                isPresented: $showsUseDestinations,
                titleVisibility: .visible,
                presenting: useDestinationModel
            ) { model in
                Button(ODLocalizedString("Assistant")) {
                    store.send(.loadModelInWorkspace(model.id, .language))
                }
                .accessibilityIdentifier("model.use.assistant.\(model.id)")
                Button(ODLocalizedString("Lens")) {
                    store.send(.loadModelInWorkspace(model.id, .vision))
                }
                .accessibilityIdentifier("model.use.lens.\(model.id)")
            } message: { model in
                Text(model.name)
            }
        }
    }

    @ViewBuilder private var modelActions: some View {
        if dynamicType.isAccessibilitySize {
            VStack(spacing: 10) { modelActionButtons }
        } else {
            HStack(spacing: 10) { modelActionButtons }
        }
    }

    @ViewBuilder private var modelActionButtons: some View {
        ODModelTopAction(title: "Import model", symbol: "square.and.arrow.down", isPrimary: true) {
            store.send(.importModel)
        }
        .disabled(!store.canPerformActions)
        .accessibilityHint(Text("Choose a model from Files", bundle: .module))
        .accessibilityIdentifier("models.import")

        ODModelTopAction(title: "Downloads", symbol: "arrow.down.circle", count: transferCount) {
            store.send(.showModelDownloads)
        }
        .disabled(!store.canPerformActions)
        .accessibilityIdentifier("models.downloads")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(ODLocalizedString(key: emptyTitle), systemImage: kind?.symbol ?? "cube")
        } description: {
            Text(odKey: emptyDetail)
        } actions: {
            if !searchText.isEmpty || kind != nil {
                Button(ODLocalizedString("Clear filters")) { searchText = ""; kind = nil }
                    .buttonStyle(.glass)
            } else if scope == .installed {
                Button(ODLocalizedString("Find a model")) { scope = .discover }
                    .buttonStyle(.glassProminent).odInkProminent()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var emptyTitle: String {
        if !searchText.isEmpty || kind != nil { return "No matching models" }
        return scope == .installed ? "No downloaded models" : "Nothing new to download"
    }
    private var emptyDetail: String {
        if !searchText.isEmpty || kind != nil { return "Try another name or capability." }
        return scope == .installed ? "Find a model for chat, vision, voice, or images."
            : "Every catalog model is already installed. Browse the model catalog for more."
    }

    /// The download action exists only while the model is actionable — never
    /// mid-download (the footer shows progress) and never once installed.
    private func showsDownloadAction(_ model: ODModel) -> Bool {
        !model.isInstalled && model.downloadStatus == nil
        && (model.availableCommands ?? store.capabilities.modelCommands).contains(.download)
    }

    private func use(_ model: ODModel) {
        guard model.isSelectable else {
            detailModel = model
            return
        }
        if model.supportedKinds.contains(.language)
            && model.supportedKinds.contains(.vision) {
            useDestinationModel = model
            showsUseDestinations = true
        } else {
            store.send(.loadModel(model.id))
        }
    }
}

private enum ODModelScope: String, CaseIterable, Identifiable {
    case installed, discover
    var id: String { rawValue }
    var title: String { self == .installed ? "On device" : "Discover" }
}

private struct ODModelTopAction: View {
    let title: String
    let symbol: String
    var count = 0
    var isPrimary = false
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(odKey: title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .accessibilityHidden(true)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isPrimary ? ODPalette.onSend : ODPalette.text)
            .frame(maxWidth: .infinity, minHeight: dynamicType.isAccessibilitySize ? 56 : 50)
            .padding(.horizontal, 8)
            .background(isPrimary ? ODPalette.send : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ODPressButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(count > 0 ? Text("\(Text(odKey: title)), \(count) active", bundle: .module) : Text(odKey: title))
    }
}

/// One-tap capability filters: visible choices instead of a hidden menu.
private struct ODCapabilityChips: View {
    @Binding var kind: ODModelKind?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", symbol: nil, selected: kind == nil, id: "all") { kind = nil }
                ForEach(ODModelKind.allCases) { option in
                    chip(option.title, symbol: option.symbol, selected: kind == option, id: option.rawValue) {
                        kind = kind == option ? nil : option
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Capability", bundle: .module))
        .accessibilityIdentifier("models.capability")
    }

    private func chip(_ title: String, symbol: String?, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.footnote.weight(.medium)).accessibilityHidden(true) }
                Text(odKey: title).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(selected ? ODPalette.onSend : ODPalette.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(selected ? AnyShapeStyle(ODPalette.send) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                        in: Capsule())
            .frame(minHeight: ODLayout.minimumHit)
            .contentShape(Capsule())
        }
        .buttonStyle(ODPressButtonStyle())
        .accessibilityLabel(Text(odKey: title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("models.capability.\(id)")
    }
}

/// A navigation row in the card language: icon tile, title, detail, chevron.
private struct ODLibraryRow: View {
    let title: String
    let detail: String
    let symbol: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ODModelIconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(odKey: title).font(.body.weight(.semibold)).foregroundStyle(ODPalette.text)
                Text(odKey: detail).font(.footnote).foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing).font(.subheadline).foregroundStyle(ODPalette.secondary)
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ODModelIconTile: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.medium))
            .foregroundStyle(ODPalette.text)
            .frame(width: 44, height: 44)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct ODModelBrandTile: View {
    let vendor: String?
    let fallback: String

    private var mark: String? {
        switch vendor {
        case "qwen": return "Q"
        case "meta": return "M"
        case "google": return "G"
        case "huggingFace", "ggmlOrg": return "H"
        case "apple": return "A"
        case "mistral": return "M"
        default: return nil
        }
    }
    var body: some View {
        Group {
            if let mark {
                Text(mark).font(.title2.weight(.bold)).foregroundStyle(.white)
            } else {
                Image(systemName: fallback).font(.title3.weight(.semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 48, height: 48)
        // Ink plate like the app icon, so vendor marks sit inside the Token identity.
        .background(Color(red: 0.043, green: 0.047, blue: 0.063), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

private struct ODModelBadge: View {
    let title: String

    private var symbol: String {
        switch title {
        case "Recommended": return "checkmark.seal.fill"
        case "Best": return "crown.fill"
        case "Vision": return "eye.fill"
        case "Thinking": return "lightbulb.fill"
        case "Fast": return "bolt.fill"
        default: return "sparkle"
        }
    }
    private var tint: Color {
        switch title {
        case "Thinking": return .purple
        case "Vision": return .green
        case "Best", "Recommended": return .teal
        default: return .blue
        }
    }

    var body: some View {
        Label(ODLocalizedString(key: title), systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.1), in: Capsule())
            .lineLimit(1)
    }
}

/// The CodeLens selection card translated to a compact, actionable phone row.
private struct ODModelCard: View {
    let model: ODModel
    let phase: ODModelPhase
    let isSelected: Bool
    let canPerformActions: Bool
    let showsDownload: Bool
    let onDetails: () -> Void
    let onUse: () -> Void
    let onDownload: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void
    @State private var cancelConfirmationPresented = false
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var title: String { ODPresentation.modelName(model.name, compact: true) }
    private var summary: String { model.summary ?? model.metadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onDetails) {
                HStack(alignment: .top, spacing: 12) {
                    if !dynamicType.isAccessibilitySize {
                        ODModelBrandTile(vendor: model.vendor, fallback: model.kind.symbol)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(ODPalette.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if let size = model.sizeLabel {
                                Text(size)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(ODPalette.secondary)
                                    .fixedSize()
                            }
                        }
                        Text(odKey: model.isInstalled && !model.isSelectable && model.kind != .classifier
                             ? "Installed · runtime unavailable"
                             : (summary.isEmpty ? model.workspaceLabel : summary))
                            .font(.subheadline)
                            .foregroundStyle(ODPalette.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.declaredKinds.contains(.language)
                            && model.declaredKinds.contains(.vision) {
                            Text(odKey: model.workspaceLabel)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ODPalette.secondary)
                        }
                        if !model.badges.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(model.badges, id: \.self) { badge in
                                    ODModelBadge(title: badge)
                                }
                            }
                        }
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3).foregroundStyle(ODPalette.text)
                            .accessibilityHidden(true)
                    }
                }
                .padding(14)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(ODPressButtonStyle())
            .accessibilityLabel(Text("Details for \(model.name)", bundle: .module))
            .accessibilityValue(Text(odKey: isSelected ? "Current model" : model.badges.joined(separator: ", ")))
            .accessibilityIdentifier("model.row.\(model.id)")

            ODHairline().padding(.horizontal, 14)
            footer
                .frame(minHeight: ODLayout.minimumHit)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? ODPalette.text.opacity(0.42) : ODPalette.line.opacity(0.6), lineWidth: isSelected ? 1.25 : 0.5)
        }
        .animation(ODMotion.fade, value: phase)
        .animation(ODMotion.fade, value: model.downloadStatus == nil)
        .confirmationDialog(ODLocalizedString("Cancel download of \(model.name)?"),
                            isPresented: $cancelConfirmationPresented, titleVisibility: .visible) {
            Button(ODLocalizedString("Cancel download"), role: .destructive, action: onCancel)
        } message: {
            Text("Downloaded files for this model will be removed. You can download it again later.", bundle: .module)
        }
    }

    @ViewBuilder private var footer: some View {
        if let status = model.downloadStatus {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(odKey: status).font(.footnote.weight(.medium)).foregroundStyle(ODPalette.text)
                        if let progress = model.downloadProgress, progress.isFinite {
                            Text("\(Int((progress * 100).rounded()))%", bundle: .module)
                                .font(.footnote.monospacedDigit()).foregroundStyle(ODPalette.secondary)
                        }
                    }
                    if status != "Download failed" {
                        ProgressView(value: model.downloadProgress.flatMap {
                            $0.isFinite ? min(1, max(0, $0)) : nil
                        })
                            .tint(ODPalette.text)
                            .accessibilityLabel(Text(odKey: model.downloadDetail == nil ? "Model download progress" : "Model preparation progress"))
                    }
                    if let detail = model.downloadDetail {
                        Text(odKey: detail).font(.footnote).foregroundStyle(ODPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if (model.availableCommands ?? []).contains(.download) || (model.availableCommands ?? []).contains(.pauseDownload) {
                circleButton(model.isDownloadPaused || status == "Download failed" ? "arrow.clockwise" : "pause.fill",
                             label: model.isDownloadPaused || status == "Download failed" ? "Resume" : "Pause",
                             id: "model.pauseResume.\(model.id)",
                             action: model.isDownloadPaused || status == "Download failed" ? onDownload : onPause)
                }
                if (model.availableCommands ?? []).contains(.cancelDownload) {
                circleButton("xmark", label: "Cancel download", id: "model.cancel.\(model.id)") {
                    cancelConfirmationPresented = true
                }
                }
            }
            .transition(.opacity)
        } else if showsDownload {
            HStack(spacing: 12) {
                Text("Available to download", bundle: .module)
                    .font(.footnote).foregroundStyle(ODPalette.secondary)
                Spacer(minLength: 8)
                Button(action: onDownload) {
                    Label(ODLocalizedString("Download"), systemImage: "arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ODPalette.onSend)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 36)
                        .background(ODPalette.send, in: Capsule())
                        .frame(minHeight: ODLayout.minimumHit)
                        .contentShape(Capsule())
                }
                .buttonStyle(ODPressButtonStyle())
                .disabled(!canPerformActions)
                .accessibilityLabel(Text("Download \(model.name)", bundle: .module))
                .accessibilityIdentifier("model.download.\(model.id)")
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 12) {
                statusLabel
                Spacer(minLength: 8)
                if isSelected && model.supportedKinds.count == 1 {
                    Text("Current", bundle: .module)
                        .font(.footnote.weight(.semibold)).foregroundStyle(ODPalette.text)
                } else if model.isInstalled {
                    Button(ODLocalizedString(key: model.isSelectable ? "Use" : "Manage")) { onUse() }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(ODPressButtonStyle())
                        .disabled(!canPerformActions || phase.isPreparing)
                        .accessibilityIdentifier("model.use.\(model.id)")
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch phase {
        case .ready:
            Label { Text("Loaded", bundle: .module) } icon: { Circle().fill(ODPalette.text).frame(width: 7, height: 7) }
                .font(.footnote.weight(.medium)).foregroundStyle(ODPalette.text)
        case .preparing:
            Text("Preparing", bundle: .module).font(.footnote.weight(.medium)).foregroundStyle(ODPalette.secondary).odShimmer()
        case .failed:
            Label(ODLocalizedString("Needs attention"), systemImage: "exclamationmark.circle.fill")
                .font(.footnote.weight(.medium)).foregroundStyle(ODPalette.red)
        case .unloaded:
            Label(ODLocalizedString(key: model.isInstalled ? "Installed" : (model.unavailableReason == nil ? "Not installed" : "Unavailable on this device")),
                  systemImage: model.isInstalled ? "checkmark.circle" : "icloud.and.arrow.down")
                .font(.footnote).foregroundStyle(ODPalette.secondary)
        }
    }

    private func circleButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(ODPalette.text)
                .frame(width: 36, height: 36)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
                .contentShape(Circle())
        }
        .buttonStyle(ODPressButtonStyle())
        .disabled(!canPerformActions)
        .accessibilityLabel(Text(odKey: label))
        .accessibilityIdentifier(id)
    }
}

/// Shared flat destination label; its parent owns navigation and enablement.
/// Deliberately quieter than the library rows above: management is secondary.
struct ODWorkspaceLinkLabel: View {
    let title: String
    let symbol: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: ODLayout.labelGap) {
            Image(systemName: symbol)
                .font(.subheadline).foregroundStyle(ODPalette.secondary)
                .frame(minWidth: ODLayout.groupGap).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ODLayout.unit) {
                Text(odKey: title).font(.subheadline).foregroundStyle(ODPalette.text)
                if let detail {
                    Text(odKey: detail).font(.caption).foregroundStyle(ODPalette.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(ODPalette.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, ODLayout.elementGap)
        .frame(maxWidth: .infinity, minHeight: ODLayout.minimumHit, alignment: .leading)
        .contentShape(Rectangle())
    }
}
