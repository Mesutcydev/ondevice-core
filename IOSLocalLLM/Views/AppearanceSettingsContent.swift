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
        Section("THEME") {
            ODAppearanceChoices(selection: $appearance)
                .padding(ODLayout.settingsPageInset)
                .background(ODPalette.surface,
                            in: RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous)
                        .strokeBorder(ODPalette.line, lineWidth: 1)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: ODLayout.settingsPageInset, bottom: 0, trailing: ODLayout.settingsPageInset))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if supportsAlternateIcons {
            Section("APP ICON") {
                iconOptions()
                    .padding(ODLayout.settingsPageInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ODPalette.surface,
                                in: RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 0, leading: ODLayout.settingsPageInset, bottom: 0, trailing: ODLayout.settingsPageInset))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        Section("PREFERENCES") {
            VStack(spacing: 0) {
                languagePicker()
                    .frame(minHeight: ODLayout.settingsRowMinimumHeight)
                Divider()
                Toggle("Haptic feedback", isOn: $hapticsEnabled)
                    .frame(minHeight: ODLayout.settingsRowMinimumHeight)
                Divider()
                Toggle("Show FPS counter", isOn: $showFPSCounter)
                    .frame(minHeight: ODLayout.settingsRowMinimumHeight)
            }
            .padding(.horizontal, ODLayout.settingsPageInset)
            .background(ODPalette.surface,
                        in: RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous)
                    .strokeBorder(ODPalette.line, lineWidth: 1)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: ODLayout.settingsPageInset, bottom: 0, trailing: ODLayout.settingsPageInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        Section("HELP") {
            Button(action: onResetTips) {
                Label("Reset onboarding tips", systemImage: "lightbulb")
                    .font(.body.weight(.medium))
                    .foregroundStyle(ODPalette.text)
                    .frame(maxWidth: .infinity, minHeight: ODLayout.settingsRowMinimumHeight, alignment: .leading)
                    .padding(.horizontal, ODLayout.settingsPageInset)
                    .background(ODPalette.surface,
                                in: RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous))
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: ODLayout.settingsPageInset, bottom: 0, trailing: ODLayout.settingsPageInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
}
