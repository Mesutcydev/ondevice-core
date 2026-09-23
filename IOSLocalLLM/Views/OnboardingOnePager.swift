import SwiftUI
import OnDeviceUI

/// Presentation only. The host records completion and owns all services.
struct OnboardingOnePager: View {
    var onFinish: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("OnDevice")
                            .font(.system(.largeTitle, design: .serif).weight(.semibold))
                        Text("A calmer place to think.")
                            .font(.title2).foregroundStyle(ODPalette.secondary)
                        Text("Chat, read what’s around you, and create with models on your device.")
                            .font(.body).padding(.top, 8)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        capability("Chat", symbol: "bubble.left", detail: "Write, ask questions, and work with your files.")
                        capability("Lens", symbol: "camera", detail: "Ask, translate, scan, or solve with your camera.")
                        capability("Voice", symbol: "waveform", detail: "Choose a voice and talk through an idea.")
                        capability("Models", symbol: "cube", detail: "Choose, download, and manage the models you use.")
                    }
                    Text("Local models process your content on this device. Downloads, optional web access, Apple Private Cloud Compute, and paired Mac tools use the network when you choose them. You control these features in Settings.")
                        .font(.footnote).foregroundStyle(ODPalette.secondary)
                }
                .padding(ODLayout.pageInset)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .safeAreaInset(edge: .bottom) {
                Button("Get started", action: onFinish)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .tint(ODPalette.text).foregroundStyle(ODPalette.background)
                    .padding(ODLayout.pageInset)
            }
        }
    }

    private func capability(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title3).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.body).foregroundStyle(ODPalette.secondary)
            }
        }
    }
}
