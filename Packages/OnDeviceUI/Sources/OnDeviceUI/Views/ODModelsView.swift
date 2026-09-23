import SwiftUI

@MainActor
struct ODModelsView: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.displayScale) private var displayScale
    @State private var scope: ODModelScope = .installed
    @State private var kind: ODModelKind?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var detailModel: ODModel?
    @State private var deferredModelAction: ODAction?

    private var installedCount: Int { store.models.filter { $0.isInstalled && $0.isLibraryEntry }.count }
    private var filteredModels: [ODModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.models.filter { model in
            model.isLibraryEntry && (scope == .installed ? model.isInstalled : !model.isInstalled)
            && (kind == nil || model.kind == kind)
            && (query.isEmpty || "\(model.name) \(model.metadata) \(model.id)".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                    ODLibraryNavigation(scope: $scope, kind: $kind)
                    if scope == .installed {
                        Text("Downloaded and imported models. Core AI packs are managed separately.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: ODLayout.labelGap) {
                        if filteredModels.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(emptyTitle).font(.title3.weight(.medium))
                                Text(emptyDetail).font(.subheadline).foregroundStyle(.secondary)
                                if !searchText.isEmpty || kind != nil {
                                    Button("Clear filters") { searchText = ""; kind = nil }
                                        .frame(minHeight: ODLayout.minimumHit)
                                } else if scope == .installed {
                                    Button("Find a model") { scope = .discover }
                                        .buttonStyle(.glass)
                                }
                            }
                            .padding(.vertical, 16)
                        } else {
                            ForEach(filteredModels) { model in
                                modelCard(model)
                            }
                        }
                    }
                    if scope == .installed && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ODLibraryUtilities(count: installedCount, storageBytes: store.metrics.modelStorageBytes,
                            canPerformActions: store.canPerformActions,
                            onStorage: { store.secondaryRoute = .device },
                            onPacks: { store.send(.openCoreAIPacks) })
                    } else if scope == .discover {
                        Button { store.send(.openDiscovery) } label: {
                            ODWorkspaceLinkLabel(title: "Browse the model catalog", symbol: "magnifyingglass",
                                detail: "Find a model for your next project.")
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canPerformActions)
                    }
                }
                .padding(.horizontal, ODLayout.pageInset)
                .padding(.top, 12)
                .padding(.bottom, ODLayout.groupGap)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { searchFocused = false }
            .onChange(of: store.conversationsPresented) { _, open in
                if open { searchFocused = false }
            }
            .onChange(of: store.selectedTab) { _, destination in
                if destination != .models { searchFocused = false }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton { store.conversationsPresented = true }
                        .labelStyle(.iconOnly)
                    .accessibilityIdentifier("navigation.menu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Discover models", systemImage: "plus") {
                        if scope == .discover { store.send(.openDiscovery) }
                        else { scope = .discover }
                    }
                        .labelStyle(.iconOnly)
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
                }.environmentObject(store)
            }
        }
    }

    private var emptyTitle: String {
        if !searchText.isEmpty || kind != nil { return "No matching models" }
        return scope == .installed ? "No models installed" : "No models to discover"
    }
    private var emptyDetail: String {
        if !searchText.isEmpty || kind != nil { return "Try another name or capability." }
        return scope == .installed ? "Find a model for chat, vision, voice, or images."
            : "Check your model catalog for available models."
    }

    /// One model, one card. The card body opens details; a discover card gets
    /// a separated footer with the one action that matters there — Download.
    private func modelCard(_ model: ODModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { detailModel = model } label: { cardBody(model) }
                .buttonStyle(.plain)
                .accessibilityHint("Shows model details and available actions")
                .accessibilityIdentifier("model.row.\(model.id)")
            if showsDownloadAction(model) {
                ODHairline()
                    .padding(.horizontal, ODLayout.bubbleInsetH)
                HStack {
                    Spacer(minLength: 0)
                    Button { store.send(.modelAction(modelID: model.id, command: .download)) } label: {
                        Label("Download", systemImage: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(ODPalette.accent, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canPerformActions)
                    .opacity(store.canPerformActions ? 1 : 0.55)
                    .accessibilityLabel("Download \(model.name)")
                    .accessibilityIdentifier("model.download.\(model.id)")
                }
                .padding(.horizontal, ODLayout.bubbleInsetH)
                .padding(.vertical, ODLayout.elementGap)
            }
        }
        .background(ODPalette.surface, in: RoundedRectangle(cornerRadius: ODLayout.corner, style: .continuous))
        // Surface and canvas are both pure white in light mode — the hairline
        // is what makes the card read as a card there. In dark mode it just
        // sharpens the raised edge.
        .overlay(
            RoundedRectangle(cornerRadius: ODLayout.corner, style: .continuous)
                .stroke(ODPalette.line, lineWidth: ODLayout.hairline(displayScale: displayScale))
        )
    }

    /// The download footer only exists while the model is actionable — never
    /// mid-download (the body shows progress) and never once installed.
    private func showsDownloadAction(_ model: ODModel) -> Bool {
        !model.isInstalled && model.downloadStatus == nil
        && (model.availableCommands ?? store.capabilities.modelCommands).contains(.download)
    }

    private func cardBody(_ model: ODModel) -> some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            HStack(alignment: .center, spacing: ODLayout.labelGap) {
                Image(systemName: model.kind.symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ODPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(ODPalette.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name.components(separatedBy: " · ").first ?? model.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ODPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(modelSpecification(model))
                        .font(.footnote).foregroundStyle(ODPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote).foregroundStyle(ODPalette.secondary)
                    .accessibilityHidden(true)
            }
            // Runtime state (Loaded/Preparing/…) is the primary signal; the
            // selection role is a separate, accent-marked fact — never styled
            // as another state.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    stateLabel(model)
                    selectionRole(model)
                }
                VStack(alignment: .leading, spacing: 6) {
                    stateLabel(model)
                    selectionRole(model)
                }
            }
        }
        .padding(ODLayout.bubbleInsetH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func selectionRole(_ model: ODModel) -> some View {
        if model.id == store.selectedModelID {
            Label("Selected", systemImage: "checkmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(ODPalette.accent)
        } else if model.isDefault {
            Text("Default for chat").font(.footnote).foregroundStyle(ODPalette.secondary)
        }
    }

    private func modelSpecification(_ model: ODModel) -> String {
        let suffix = model.name.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        return [model.kind.title, suffix.isEmpty ? model.metadata : suffix, model.sizeLabel]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func stateLabel(_ model: ODModel) -> some View {
        if let status = model.downloadStatus {
            HStack(spacing: ODLayout.elementGap) {
                ProgressView(value: model.downloadProgress).frame(maxWidth: 80)
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
        switch store.phase(for: model) {
        case .ready:
            Label("Loaded", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(ODPalette.text)
        case .preparing:
            HStack(spacing: ODLayout.elementGap) {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                Text("Preparing").font(.footnote).foregroundStyle(ODPalette.secondary)
            }
        case .failed:
            Label("Needs attention", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
        case .unloaded:
            if model.isInstalled { Text("Installed").font(.footnote).foregroundStyle(ODPalette.secondary) }
        }
        }
    }
}

private enum ODModelScope: String, CaseIterable, Identifiable {
    case installed, discover
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct ODLibraryNavigation: View {
    @Binding var scope: ODModelScope
    @Binding var kind: ODModelKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Model library", selection: $scope) {
                ForEach(ODModelScope.allCases) { option in
                    Text(option.title).tag(option).accessibilityIdentifier("models.scope.\(option.rawValue)")
                }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("models.scope")
            Menu {
                Picker("Capability", selection: $kind) {
                    Text("All models").tag(ODModelKind?.none)
                    ForEach(ODModelKind.allCases) { option in Text(option.title).tag(Optional(option)) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(kind?.title ?? "All capabilities")
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.subheadline).foregroundStyle(ODPalette.secondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Capability")
            .accessibilityValue(kind?.title ?? "All models")
            .accessibilityIdentifier("models.capability")
        }
    }
}

private struct ODLibraryUtilities: View {
    let count: Int
    let storageBytes: Int64?
    let canPerformActions: Bool
    let onStorage: () -> Void
    let onPacks: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage your library").font(.subheadline.weight(.medium))
                .foregroundStyle(ODPalette.secondary).accessibilityAddTraits(.isHeader)
            Button(action: onStorage) {
                ODWorkspaceLinkLabel(title: "Device storage", symbol: "internaldrive",
                    detail: "\(count) in catalog · \(storageBytes.map(ODFormat.bytes) ?? "Unmeasured") in model files and cache")
            }
            .accessibilityIdentifier("models.storage")
            Divider().overlay(ODPalette.line)
            Button(action: onPacks) {
                ODWorkspaceLinkLabel(title: "Core AI packs", symbol: "cpu",
                    detail: "Download and manage Core AI models.")
            }
            .disabled(!canPerformActions)
            .accessibilityIdentifier("models.corePacks")
        }
        .buttonStyle(.plain)
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
                Text(title).font(.subheadline).foregroundStyle(ODPalette.text)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(ODPalette.secondary)
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
