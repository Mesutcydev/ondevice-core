import SwiftUI

@MainActor
struct ODSettingsView: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dismiss) private var dismiss
    @State private var devicePresented = false
    @AppStorage("uiLanguage") private var uiLanguage = "system"

    var body: some View {
        NavigationStack {
            List {
                Section(ODLocalizedString("Appearance")) {
                    ODAppearanceChoices(selection: $store.appearance)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                Section(ODLocalizedString("Language")) {
                    ODLanguagePicker(selection: Binding(
                        get: { ODAppLanguage(rawValue: uiLanguage) ?? .system },
                        set: { uiLanguage = $0.rawValue }
                    ))
                }
                Section(ODLocalizedString("Models & voice")) {
                    Button {
                        store.selectedTab = .models
                        dismiss()
                    } label: {
                        LabeledContent {
                            Text(odKey: store.selectedModel?.name ?? "Choose").foregroundStyle(.secondary)
                        } label: {
                            Label(ODLocalizedString("Models"), systemImage: "cube").foregroundStyle(ODPalette.text)
                        }
                    }
                    Button {
                        store.selectedTab = .voice
                        dismiss()
                    } label: {
                        LabeledContent {
                            Text(odKey: store.selectedVoice?.name ?? "Choose").foregroundStyle(.secondary)
                        } label: {
                            Label(ODLocalizedString("Voice"), systemImage: "waveform").foregroundStyle(ODPalette.text)
                        }
                    }
                }
                Section(ODLocalizedString("Device")) {
                    Button { devicePresented = true } label: {
                        Label(ODLocalizedString("Storage"), systemImage: "internaldrive")
                    }
                    Button { devicePresented = true } label: {
                        Label(ODLocalizedString("Diagnostics"), systemImage: "waveform.path.ecg")
                    }
                    .accessibilityHint(Text("Shows memory and thermal measurements", bundle: .module))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .odNavigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ODLocalizedString("Close"), systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $devicePresented) { ODSystemView().environmentObject(store) }
        }
        .environment(\.locale, ODLocalization.locale(for: ODAppLanguage(rawValue: uiLanguage) ?? .system))
        .environment(\.layoutDirection, ODLocalization.resolvedLanguage(ODAppLanguage(rawValue: uiLanguage) ?? .system).isRightToLeft ? .rightToLeft : .leftToRight)
        .preferredColorScheme(store.appearance.colorScheme)
        .environment(\.odAppearance, store.appearance)
    }
}
