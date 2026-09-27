import SwiftUI

@MainActor
struct ODSettingsView: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dismiss) private var dismiss
    @State private var devicePresented = false

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    ODAppearanceChoices(selection: $store.appearance)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                Section("Models & voice") {
                    Button {
                        store.selectedTab = .models
                        dismiss()
                    } label: {
                        LabeledContent {
                            Text(store.selectedModel?.name ?? "Choose").foregroundStyle(.secondary)
                        } label: {
                            Label("Models", systemImage: "cube").foregroundStyle(ODPalette.text)
                        }
                    }
                    Button {
                        store.selectedTab = .voice
                        dismiss()
                    } label: {
                        LabeledContent {
                            Text(store.selectedVoice?.name ?? "Choose").foregroundStyle(.secondary)
                        } label: {
                            Label("Voice", systemImage: "waveform").foregroundStyle(ODPalette.text)
                        }
                    }
                }
                Section("Device") {
                    Button { devicePresented = true } label: {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    Button { devicePresented = true } label: {
                        Label("Diagnostics", systemImage: "waveform.path.ecg")
                    }
                    .accessibilityHint("Shows memory and thermal measurements")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $devicePresented) { ODSystemView().environmentObject(store) }
        }
        .preferredColorScheme(store.appearance.colorScheme)
        .environment(\.odAppearance, store.appearance)
    }
}
