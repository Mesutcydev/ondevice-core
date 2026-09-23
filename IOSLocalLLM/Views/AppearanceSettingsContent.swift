import SwiftUI
import OnDeviceUI

/// Presentation only. The host owns persistence, icon changes, localization and tips.
struct AppearanceSettingsContent<IconOptions: View, LanguagePicker: View>: View {
    @Binding var appearance: ODAppearancePreference
    @Binding var hapticsEnabled: Bool
    @Binding var showFPSCounter: Bool
    var supportsAlternateIcons: Bool
    @ViewBuilder var iconOptions: () -> IconOptions
    @ViewBuilder var languagePicker: () -> LanguagePicker
    let onResetTips: () -> Void

    var body: some View {
        Section {
            ODAppearanceChoices(selection: $appearance)
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
        }
        if supportsAlternateIcons {
            Section("App icon") { iconOptions() }
        }
        Section("Preferences") {
            languagePicker()
            Toggle("Haptic feedback", isOn: $hapticsEnabled)
            Toggle("Show FPS counter", isOn: $showFPSCounter)
        }
        Section {
            Button(action: onResetTips) {
                Label("Reset onboarding tips", systemImage: "lightbulb")
                    .foregroundStyle(ODPalette.text)
            }
        }
    }
}
