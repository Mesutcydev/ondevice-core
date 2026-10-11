import SwiftUI
import OnDeviceUI

nonisolated final class APIProviderReviewCredentials: APIProviderCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: String] = [:]
    var failWrites = false
    func key(for id: UUID) throws -> String? { lock.withLock { keys[id] } }
    func setKey(_ key: String, for id: UUID) throws {
        try lock.withLock {
            if failWrites { throw APIProviderError.credentialStorage }
            keys[id] = key
        }
    }
    func deleteKey(for id: UUID) throws { lock.withLock { _ = keys.removeValue(forKey: id) } }
    func deleteAll() throws { lock.withLock { keys.removeAll() } }
}

nonisolated struct APIProviderReviewCatalog: APIProviderModelFetching {
    func fetchModels(provider: APIProviderConfiguration, key: String) async throws -> [APIProviderModel] {
        [.init(id: "fixture-chat", name: "Project model", contextWindow: 32_768),
         .init(id: "fixture-vision", name: "Project vision", contextWindow: 65_536, supportsImages: true)]
    }
}

@MainActor
final class APIProviderReviewState: ObservableObject {
    let providers: APIProviderStore
    let catalog = APIProviderReviewCatalog()
    init() {
        let defaults = UserDefaults(suiteName: "api-provider-review")!
        defaults.removePersistentDomain(forName: "api-provider-review")
        providers = APIProviderStore(defaults: defaults, credentials: APIProviderReviewCredentials())
        if !ProcessInfo.processInfo.arguments.contains("-api-empty") {
            var provider = APIProviderConfiguration(kind: .openRouter)
            provider.models = [.init(id: "fixture-chat", name: "Project model", contextWindow: 32_768),
                               .init(id: "fixture-vision", name: "Project vision", supportsImages: true)]
            try? providers.save(provider, newKey: "fixture-key")
        }
    }
}

struct APIProviderSettingsReview: View {
    @StateObject private var fixture = APIProviderReviewState()
    var body: some View {
        NavigationStack { APIProvidersView(store: fixture.providers, client: fixture.catalog) }
    }
}

struct APIProviderChatReview: View {
    @EnvironmentObject private var workbench: ODStore
    @StateObject private var fixture = APIProviderReviewState()
    @State private var selectedID = "local-fixture"
    @State private var modelPresented = false
    @State private var draft = "Keep my project draft"
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var modelName: String {
        fixture.providers.target(selectedID)?.model.name ?? "Qwen3 4B"
    }

    private var modelControl: some View {
        Button { focused = false; modelPresented = true } label: {
            ODModelMenuLabel(displayName: modelName, preservesName: selectedID.hasPrefix("api:"))
        }
        .buttonStyle(.plain).accessibilityLabel("Choose chat model")
        .accessibilityValue(modelName).accessibilityIdentifier("chat.modelPicker")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("UI fixture · no network requests").font(.caption).foregroundStyle(.secondary)
                    Text("Project chat").font(.title2.weight(.semibold))
                    Text("Choose a chat model. Provider selection keeps this conversation and its draft in place.")
                }.padding(ODLayout.pageInset)
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Project audit").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton { focused = false; workbench.conversationsPresented = true }
                        .accessibilityIdentifier("navigation.menu")
                }
                ToolbarItem(placement: .principal) {
                    modelControl
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODWorkspaceBottomBar(backgroundColor: ODPalette.background) {
                    VStack(spacing: 0) {
                        ODComposer(text: $draft, focus: $focused, attachments: [], isResponding: false,
                            canSend: true, canStop: false, canAdd: true, canRemove: true,
                            onAdd: {}, onRemove: { _ in }, onSend: { _, _ in }, onStop: {})
                        if focused {
                            HStack { ODKeyboardDismissKey(focus: $focused); Spacer() }
                                .padding(.horizontal, ODLayout.pageInset).frame(minHeight: 44)
                        }
                    }
                }
            }
            .sheet(isPresented: $modelPresented) {
                NavigationStack {
                    List {
                        Section("Available on this device") {
                            Button { selectedID = "local-fixture"; modelPresented = false } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "internaldrive")
                                        .frame(width: 34, height: 34)
                                        .background(ODPalette.text.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Qwen3 4B").font(.body.weight(.semibold))
                                        Text("Local model · UI fixture").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                }.foregroundStyle(ODPalette.text).frame(minHeight: 48)
                            }.accessibilityLabel("Qwen3 4B")
                        }
                        APIProviderModelSection(store: fixture.providers, client: fixture.catalog, selectedID: selectedID) {
                            selectedID = $0
                            modelPresented = false
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden).background { ODPageBackground().ignoresSafeArea() }
                    .navigationTitle("Chat model").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { modelPresented = false } } }
                }
                .dynamicTypeSize(typeSize)
            }
        }
    }
}
