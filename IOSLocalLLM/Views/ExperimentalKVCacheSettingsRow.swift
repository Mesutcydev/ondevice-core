import SwiftUI

/// Kept independent of the heavy runtime so the production control can be
/// exercised in QA/NativeUI. The value is snapshotted when a reply starts.
struct ExperimentalKVCacheSettingsRow: View {
    @Binding var enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("TurboQuant cache (experimental)", isOn: $enabled)
                .accessibilityIdentifier("settings.turboQuantEnabled")
            Text("Uses less cache memory for supported text models. Speed and output quality can change. Applies to the next reply.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
