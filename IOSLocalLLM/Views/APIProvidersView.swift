import SwiftUI
import OnDeviceUI

/// Shared production settings, also exercised directly by the NativeUI harness.
struct APIProvidersView: View {
    @ObservedObject var store: APIProviderStore = .shared
    var client: any APIProviderModelFetching = APIProviderClient.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var editing: APIProviderConfiguration?
    @State private var error: String?

    var body: some View {
        List {
            ODSettingsSection(title: "Chat models") {
                APIProviderHeading(title: "Connect an API provider", subtitle: "Choose its model from the chat model picker.", symbol: "network")
                APIProviderRule()
                Text("API providers receive the conversation context you send, including attached file excerpts and supported images. Their pricing and privacy terms apply.")
                    .font(.footnote).foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(ODLayout.settingsPageInset)
            }
            if store.providers.isEmpty {
                ODSettingsSection(title: "Configured providers") {
                    APIProviderHeading(title: "No API providers", subtitle: "Add a provider, then refresh or enter a model ID.", symbol: "cube")
                }
            }
            ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, provider in
                ODSettingsSection(title: index == 0 ? "Configured providers" : "") {
                    NavigationLink {
                        APIProviderModelsView(store: store, providerID: provider.id, client: client)
                    } label: {
                        APIProviderSummary(provider: provider, hasKey: store.hasKey(for: provider.id))
                    }
                    .buttonStyle(.plain).padding(.trailing, ODLayout.settingsPageInset)
                    .accessibilityIdentifier("api.provider.\(provider.id)")
                    .contextMenu { Button("Delete provider", role: .destructive) { delete(provider) } }
                }
            }
            ODSettingsSection(title: "",
                footer: "API keys stay in device-only Keychain. Saving settings does not send a request.") {
                APIProviderActionRow(title: "Add provider", symbol: "plus") {
                    editing = APIProviderConfiguration(kind: .openAI)
                }.accessibilityIdentifier("api.providers.add")
            }
            if let error { APIProviderErrorSection(message: error) }
        }
        .navigationTitle("API providers").navigationBarTitleDisplayMode(.inline)
        .modifier(APIProviderPageStyle())
        .sheet(item: $editing) { provider in
            APIProviderEditor(store: store, initial: provider)
                .dynamicTypeSize(typeSize).preferredColorScheme(colorScheme)
        }
    }
    private func delete(_ provider: APIProviderConfiguration) {
        do { try store.delete(provider.id); error = nil }
        catch { self.error = APIProviderClient.safeError(error) }
    }
}

struct APIProviderModelSection: View {
    @ObservedObject var store: APIProviderStore = .shared
    var client: any APIProviderModelFetching = APIProviderClient.shared
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        Section {
            // Separate native rows keep each destination's activation independent.
            ForEach(store.providers) { provider in
                NavigationLink {
                    APIProviderModelsView(store: store, providerID: provider.id,
                                          client: client, selectedID: selectedID, onSelect: onSelect)
                } label: {
                    APIProviderPickerRow(title: provider.name,
                        subtitle: !provider.isEnabled ? "Disabled"
                            : provider.requiresAPIKey && !store.hasKey(for: provider.id) ? "API key required"
                            : "\(provider.models.count) models · \(provider.endpointHost)",
                        symbol: "network")
                }
                .accessibilityIdentifier("api.provider.\(provider.id)")
            }
            NavigationLink {
                APIProvidersView(store: store, client: client)
            } label: {
                APIProviderPickerRow(title: store.providers.isEmpty ? "Add API provider" : "Manage API providers",
                                     symbol: "slider.horizontal.3")
            }
            .accessibilityIdentifier("api.providers.manage")
        } header: {
            Text("API providers").textCase(nil)
        }
    }
}

/// Matches the native local model rows without nesting Settings cards in a List cell.
private struct APIProviderPickerRow: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(ODPalette.text)
                .frame(width: 34, height: 34)
                .background(ODPalette.text.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(ODPalette.text)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(ODPalette.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

private struct APIProviderSummary: View {
    let provider: APIProviderConfiguration
    let hasKey: Bool
    var body: some View {
        APIProviderHeading(title: provider.name,
            subtitle: !provider.isEnabled ? "Disabled" : provider.requiresAPIKey && !hasKey ? "API key required"
                : "\(provider.models.count) models · \(provider.endpointHost)",
            symbol: "network")
    }
}

struct APIProviderModelsView: View {
    @ObservedObject var store: APIProviderStore
    let providerID: UUID
    var client: any APIProviderModelFetching = APIProviderClient.shared
    var selectedID: String = ""
    var onSelect: ((String) -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var editing: APIProviderConfiguration?
    @State private var modelID = ""
    @State private var search = ""
    @State private var error: String?
    @State private var refreshing = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var pendingModel: APIProviderModel?
    @FocusState private var manualModelFocused: Bool

    private var provider: APIProviderConfiguration? { store.provider(providerID) }
    private var models: [APIProviderModel] {
        (provider?.models ?? []).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        List {
            if let provider {
                connectionSection(provider)
                if let error { APIProviderErrorSection(message: error) }
                ODSettingsSection(title: "Models") {
                    if models.isEmpty {
                        Text(search.isEmpty ? "Refresh the catalog or add a model ID below." : "No matching models")
                            .font(.subheadline).foregroundStyle(ODPalette.secondary)
                            .padding(ODLayout.settingsPageInset)
                    }
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        if index > 0 { APIProviderRule() }
                        if onSelect != nil {
                            Button { choose(model, provider: provider) } label: { modelLabel(model, provider: provider) }
                                .buttonStyle(.plain).disabled(!store.canUse(provider))
                                .accessibilityIdentifier("api.model.\(model.id)")
                        } else {
                            modelLabel(model, provider: provider)
                        }
                    }
                }
                ODSettingsSection(title: "Add manually",
                    footer: "Use the exact model ID from your provider, including endpoints without a model catalog.") {
                    APIProviderField(title: "Model ID") {
                        TextField("Enter model ID", text: $modelID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($manualModelFocused).submitLabel(.done)
                            .onSubmit { addModel(provider) }
                            .accessibilityIdentifier("api.modelID")
                    }
                    APIProviderRule()
                    APIProviderActionRow(title: "Add model", symbol: "plus") { addModel(provider) }
                        .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("api.models.add")
                }
            } else {
                ODSettingsSection(title: "Connection") {
                    APIProviderHeading(title: "Provider removed", subtitle: "Choose another provider or an on-device model.", symbol: "network")
                }
            }
        }
        .navigationTitle(provider?.name ?? "API models").navigationBarTitleDisplayMode(.inline)
        .modifier(APIProviderPageStyle())
        .searchable(text: $search, prompt: "Search models")
        .sheet(item: $editing) {
            APIProviderEditor(store: store, initial: $0)
                .dynamicTypeSize(typeSize).preferredColorScheme(colorScheme)
        }
        .sheet(item: $pendingModel) { model in
            if let provider {
                APIProviderConsentView(provider: provider) {
                    do {
                        try store.acceptConsent(for: provider.id, fingerprint: provider.privacyFingerprint)
                        pendingModel = nil
                        onSelect?(provider.selectionID(for: model))
                    } catch { self.error = APIProviderClient.safeError(error); pendingModel = nil }
                }
                .dynamicTypeSize(typeSize).preferredColorScheme(colorScheme)
            }
        }
        .onDisappear { refreshTask?.cancel() }
    }
    private func connectionSection(_ provider: APIProviderConfiguration) -> some View {
        let credentialStatus = store.hasKey(for: provider.id) ? "Saved in Keychain" : provider.requiresAPIKey ? "Required" : "Not required"
        return ODSettingsSection(title: "Connection",
            footer: "Refresh sends your credential to this endpoint to retrieve its model catalog. Conversation content is not included.") {
            APIProviderValueRow(title: "Provider", value: provider.kind.name)
            APIProviderRule()
            APIProviderValueRow(title: "Endpoint", value: provider.endpointHost)
            APIProviderRule()
            APIProviderValueRow(title: "API key", value: credentialStatus)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("API key").accessibilityValue(credentialStatus)
                .accessibilityIdentifier("api.provider.keyStatus")
            APIProviderRule()
            APIProviderActionRow(title: "Configure provider", symbol: "slider.horizontal.3") {
                manualModelFocused = false
                editing = provider
            }
                .accessibilityIdentifier("api.provider.configure")
            APIProviderRule()
            APIProviderActionRow(title: refreshing ? "Refreshing models…" : "Refresh models",
                                 symbol: "arrow.clockwise", isWorking: refreshing, action: refresh)
                .disabled(refreshing || !store.canUse(provider))
                .accessibilityIdentifier("api.models.refresh")
        }
    }
    private func modelLabel(_ model: APIProviderModel, provider: APIProviderConfiguration) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name).font(.subheadline.weight(.medium)).foregroundStyle(ODPalette.text)
                if model.id != model.name {
                    Text(model.id).font(.footnote).foregroundStyle(ODPalette.secondary)
                }
                if model.supportsImages || provider.allowImages {
                    Label("Image input enabled", systemImage: "photo").font(.caption).foregroundStyle(ODPalette.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if provider.selectionID(for: model) == selectedID {
                Image(systemName: "checkmark").foregroundStyle(ODPalette.text).accessibilityLabel("Selected")
            }
        }
        .padding(.horizontal, ODLayout.settingsPageInset).padding(.vertical, 12)
        .frame(minHeight: ODLayout.settingsRowMinimumHeight).contentShape(Rectangle())
    }
    private func choose(_ model: APIProviderModel, provider: APIProviderConfiguration) {
        if provider.hasConsent { onSelect?(provider.selectionID(for: model)) }
        else { pendingModel = model }
    }
    private func addModel(_ provider: APIProviderConfiguration) {
        var updated = provider
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIProviderEndpoint.isValidModelID(id) else { error = APIProviderError.invalidModel.localizedDescription; return }
        if !updated.models.contains(where: { $0.id == id }) {
            updated.models.append(.init(id: id, name: id, isManual: true))
        }
        do { try store.save(updated); modelID = ""; manualModelFocused = false; error = nil }
        catch { self.error = APIProviderClient.safeError(error) }
    }
    private func refresh() {
        guard let provider else { return }
        refreshing = true
        error = nil
        refreshTask = Task { @MainActor in
            defer { refreshing = false }
            do {
                let key = try store.key(for: provider)
                NetworkActivityMonitor.shared.begin(label: "API model catalog")
                defer { NetworkActivityMonitor.shared.end(label: "API model catalog") }
                let models = try await client.fetchModels(provider: provider, key: key)
                try Task.checkCancellation()
                try store.replaceCatalog(models, for: provider.id, matching: provider.privacyFingerprint)
            } catch {
                if !Task.isCancelled { self.error = APIProviderClient.safeError(error) }
            }
        }
    }
}

struct APIProviderEditor: View {
    @ObservedObject var store: APIProviderStore
    let initial: APIProviderConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var draft: APIProviderConfiguration
    @State private var key = ""
    @State private var removeKey = false
    @State private var error: String?

    init(store: APIProviderStore, initial: APIProviderConfiguration) {
        self.store = store
        self.initial = initial
        _draft = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            List {
                if let error { APIProviderErrorSection(message: error) }
                ODSettingsSection(title: "Provider") {
                    APIProviderMenuRow(title: "Service", value: draft.kind.name, selection: $draft.kind) {
                        ForEach(APIProviderKind.allCases) { Text($0.name).tag($0) }
                    }.accessibilityIdentifier("api.provider.kind")
                    APIProviderRule()
                    APIProviderField(title: "Name") {
                        TextField("Provider name", text: $draft.name).accessibilityIdentifier("api.provider.name")
                    }
                    APIProviderRule()
                    APIProviderToggleRow(title: "Enabled", isOn: $draft.isEnabled)
                }
                ODSettingsSection(title: "Connection",
                    footer: "Include the API version path. HTTPS is required outside a private network. Changing this endpoint removes its saved key and requires new consent.") {
                    APIProviderField(title: "Base URL") {
                        TextField("https://…/v1", text: $draft.baseURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("api.provider.endpoint")
                    }
                    APIProviderRule()
                    APIProviderMenuRow(title: "API format", value: draft.format.name, selection: $draft.format) {
                        ForEach(APIProviderFormat.allCases) { Text($0.name).tag($0) }
                    }.accessibilityIdentifier("api.provider.format")
                    if draft.kind == .custom {
                        APIProviderRule()
                        APIProviderToggleRow(title: "Requires API key", isOn: $draft.requiresAPIKey)
                    }
                }
                ODSettingsSection(title: "Credential",
                    footer: "Stored in device-only Keychain. Your saved key is never displayed here.") {
                    APIProviderField(title: "API key") {
                        SecureField(store.hasKey(for: draft.id) && !removeKey ? "Replace saved API key" : "Enter API key", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(!draft.requiresAPIKey)
                            .accessibilityIdentifier("api.provider.key")
                    }
                    if store.hasKey(for: draft.id) {
                        Label(removeKey ? "Key will be removed" : "API key saved in Keychain", systemImage: "lock.fill")
                            .font(.footnote).foregroundStyle(ODPalette.secondary)
                            .padding(.horizontal, ODLayout.settingsPageInset).padding(.bottom, 12)
                        APIProviderRule()
                        APIProviderToggleRow(title: "Remove saved key", isOn: $removeKey)
                    }
                }
                ODSettingsSection(title: "Conversation limits",
                    footer: "Earlier text is compacted at the retained input limit. Use limits and image input supported by your model; larger requests may cost more.") {
                    APIProviderMenuRow(title: "Input retained", value: "\(draft.inputTokenBudget.formatted()) tokens", selection: $draft.inputTokenBudget) {
                        ForEach([4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144, 1_000_000], id: \.self) {
                            Text("\($0.formatted()) tokens").tag($0)
                        }
                    }
                    APIProviderRule()
                    APIProviderMenuRow(title: "Maximum output", value: "\(draft.maximumOutputTokens.formatted()) tokens", selection: $draft.maximumOutputTokens) {
                        ForEach([1_024, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536], id: \.self) {
                            Text("\($0.formatted()) tokens").tag($0)
                        }
                    }
                    APIProviderRule()
                    APIProviderToggleRow(title: "Allow image input", isOn: $draft.allowImages)
                }
            }
            .navigationTitle(store.provider(initial.id) == nil ? "Add provider" : "Configure provider")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(APIProviderPageStyle())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).accessibilityIdentifier("api.provider.save")
                }
            }
            .onChange(of: draft.kind) { old, new in
                if draft.name == old.name { draft.name = new.name }
                draft.baseURL = new.baseURL
                draft.format = new.format
                draft.requiresAPIKey = true
                draft.models = APIProviderConfiguration(kind: new).models
                key = ""
            }
        }
        .tint(ODPalette.text)
    }
    private func save() {
        do { try store.save(draft, newKey: key, removeKey: removeKey); key = ""; dismiss() }
        catch { self.error = APIProviderClient.safeError(error) }
    }
}

struct APIProviderConsentView: View {
    let provider: APIProviderConfiguration
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ODSettingsSection(title: "API privacy") {
                    APIProviderHeading(title: "Use \(provider.name) for this chat", subtitle: provider.endpointHost, symbol: "network")
                    APIProviderRule()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("When you send a message, conversation text, system instructions, tool results, attached file excerpts, and supported images included in the request will be sent to this endpoint.")
                        Text("The provider may route requests to its model operators. Its privacy, retention, and billing terms apply. OnDevice Max cannot verify a custom server's practices.")
                        Text("You can choose an on-device model at any time. Local inference never silently switches to an API provider.")
                        if URL(string: provider.baseURL)?.scheme == "http" {
                            Label("This private-network endpoint uses HTTP. Requests and its API key are not encrypted in transit.", systemImage: "lock.open")
                        }
                    }
                    .font(.subheadline).foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(ODLayout.settingsPageInset)
                }
                ODSettingsSection(title: "Your choice") {
                    VStack(spacing: 12) {
                        Button(action: onAccept) {
                            Text("Use API model").frame(maxWidth: .infinity, minHeight: ODLayout.minimumHit)
                        }
                        .buttonStyle(.glassProminent).controlSize(.large).odInkProminent()
                        .accessibilityIdentifier("api.consent.accept")
                        Button("Cancel", role: .cancel) { dismiss() }
                            .frame(maxWidth: .infinity, minHeight: ODLayout.minimumHit)
                            .accessibilityIdentifier("api.consent.cancel")
                    }
                    .font(.subheadline.weight(.semibold)).padding(ODLayout.settingsPageInset)
                }
            }
            .navigationTitle("API privacy").navigationBarTitleDisplayMode(.inline)
            .modifier(APIProviderPageStyle())
        }
        .tint(ODPalette.text)
    }
}

private struct APIProviderHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.subheadline)
                .foregroundStyle(ODPalette.text)
                .frame(width: ODLayout.settingsIconSize, height: ODLayout.settingsIconSize)
                .background(ODPalette.selected, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(ODPalette.text)
                Text(subtitle).font(.footnote).foregroundStyle(ODPalette.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(ODLayout.settingsPageInset)
        .frame(minHeight: ODLayout.settingsRowMinimumHeight).contentShape(Rectangle())
    }
}

private struct APIProviderRule: View {
    var body: some View { Rectangle().fill(ODPalette.line).frame(height: 1).accessibilityHidden(true) }
}

private struct APIProviderValueRow: View {
    let title: String
    let value: String
    var isMenu = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).foregroundStyle(ODPalette.text)
                    valueLabel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    Text(title).foregroundStyle(ODPalette.text)
                    Spacer(minLength: 8)
                    valueLabel
                }
            }
        }
        .font(.subheadline).padding(.horizontal, ODLayout.settingsPageInset).padding(.vertical, 12)
        .frame(minHeight: ODLayout.settingsRowMinimumHeight)
        .contentShape(Rectangle())
    }
    private var valueLabel: some View {
        HStack(spacing: 6) {
            Text(value).foregroundStyle(ODPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            if isMenu {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold)).foregroundStyle(ODPalette.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct APIProviderMenuRow<Selection: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    @ViewBuilder let options: () -> Options
    var body: some View {
        Menu {
            Picker(title, selection: $selection, content: options)
        } label: {
            APIProviderValueRow(title: title, value: value, isMenu: true)
        }
        .buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(value)
    }
}

private struct APIProviderField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(ODPalette.secondary)
            content().font(.subheadline).foregroundStyle(ODPalette.text)
        }
        .padding(.horizontal, ODLayout.settingsPageInset).padding(.vertical, 12)
        .frame(minHeight: ODLayout.settingsRowMinimumHeight)
    }
}

private struct APIProviderToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn).font(.subheadline).tint(ODPalette.text)
            .padding(.horizontal, ODLayout.settingsPageInset).padding(.vertical, 8)
            .frame(minHeight: ODLayout.settingsRowMinimumHeight)
    }
}

private struct APIProviderActionRow: View {
    let title: String
    let symbol: String
    var isWorking = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isWorking { ProgressView().tint(ODPalette.text) }
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(ODPalette.text)
            .padding(.horizontal, ODLayout.settingsPageInset).padding(.vertical, 12)
            .frame(minHeight: ODLayout.settingsRowMinimumHeight).contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }.buttonStyle(.plain)
    }
}

private struct APIProviderErrorSection: View {
    let message: String
    var body: some View {
        ODSettingsSection(title: "Check configuration") {
            Text(message).font(.footnote).foregroundStyle(ODPalette.red)
                .fixedSize(horizontal: false, vertical: true).padding(ODLayout.settingsPageInset)
                .accessibilityIdentifier("api.error")
        }
    }
}

private struct APIProviderPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.plain).listSectionSpacing(16)
            .scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .foregroundStyle(ODPalette.text).tint(ODPalette.text)
    }
}
