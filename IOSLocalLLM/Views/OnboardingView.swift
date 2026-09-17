import SwiftUI

/// A short product introduction followed by explicit, device-aware model setup.
/// Only the visible step exists, so the voice preview cannot render offscreen.
struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var page = 0
    @State private var preview = 0
    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var previewPhase: VoiceSessionPhase {
        switch preview {
        case 1: .thinking
        case 2: .speaking
        default: .listening
        }
    }

    var body: some View {
        ZStack {
            LiquidPinkBackdrop()
            VStack(spacing: 0) {
                header
                if page == 2 {
                    OnboardingModelPickerView { settings.hasSeenOnboarding = true }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if page == 0 { welcome } else { privacy }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 22)
                        .padding(.bottom, 24)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                    .safeAreaInset(edge: .bottom, spacing: 0) { navigation }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if page > 0 {
                Button { advance(to: page - 1) } label: {
                    Image(systemName: "chevron.left")
                        .font(T.sans(16, .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Previous step")
            } else {
                Image("app_logo_small")
                    .resizable().scaledToFit().frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
            Text("OnDevice Core")
                .font(T.sans(15, .semibold))
            Spacer(minLength: 4)
            Button("Explore first") { settings.hasSeenOnboarding = true }
                .font(T.sans(13))
                .foregroundStyle(T.ink2)
                .frame(minHeight: 44)
                .accessibilityHint("Skip setup. Choose models later in the Models tab.")
        }
        .foregroundStyle(T.ink)
        .buttonStyle(KTactileButtonStyle())
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            eyebrow("WELCOME TO YOUR STUDIO")
            Text("Powerful AI.\nCloser to you.")
                .font(T.display(36, .semibold)).tracking(-1)
                .foregroundStyle(T.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Write, see, and speak with models running on your device.")
                .font(T.sans(16)).foregroundStyle(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        VStack(spacing: 6) {
            VoiceActivityOrb(phase: previewPhase, micLevel: preview == 2 ? 0.45 : 0.18,
                             reduceMotion: reduceMotion, samplesLiveAudio: false)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 130 : 160)
                .accessibilityLabel("Voice appearance preview")
            if dynamicTypeSize.isAccessibilitySize {
                previewPicker.pickerStyle(.menu)
            } else {
                previewPicker.pickerStyle(.segmented)
            }
            Text("A preview of voice. Your microphone is off.")
                .font(T.sans(12)).foregroundStyle(T.ink2)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        VStack(spacing: 14) {
            feature("text.bubble", title: "Assistant", detail: "Ask questions, shape ideas, and make writing your own.")
            feature("viewfinder", title: "Lens", detail: "Bring text and images into the conversation.")
            feature("waveform", title: "Voice", detail: "Talk naturally and choose the voice that suits you.")
        }
    }

    private var previewPicker: some View {
        Picker("Preview a voice state", selection: $preview) {
            Text("Listen").tag(0)
            Text("Think").tag(1)
            Text("Speak").tag(2)
        }
        .accessibilityIdentifier("onboardingVoicePreview")
    }

    @ViewBuilder
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 12) {
            eyebrow("YOU CHOOSE WHAT CONNECTS")
            Text("Local by default.\nYours to control.")
                .font(T.display(36, .semibold)).tracking(-1)
                .foregroundStyle(T.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Start with models that fit your device. Add more when you need them.")
                .font(T.sans(16)).foregroundStyle(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 26) {
            feature("arrow.down.circle", title: "Download once. Use offline.",
                    detail: "Model downloads need internet and storage. Downloaded local models run on your device.")
            feature("network", title: "Connections are your choice.",
                    detail: "Cloud providers, web tools, and Mac connections are optional. Using them can send content off your device.")
            feature("slider.horizontal.3", title: "Build your own collection.",
                    detail: "Find chat, vision, voice, and image models in Models. You can change your choices later.")
        }
        .padding(20)
        .kGlass(cornerRadius: 20, fallbackFill: T.surface)
        Label("Need a hand? The User Guide is in Settings.", systemImage: "book.closed")
            .font(T.sans(13)).foregroundStyle(T.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text).font(T.mono(10, .medium)).tracking(1.2).foregroundStyle(T.ink2)
    }

    private func feature(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(T.sans(20)).foregroundStyle(T.ink)
                .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(T.sans(15, .semibold)).foregroundStyle(T.ink)
                Text(detail).font(T.sans(14)).foregroundStyle(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var navigation: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule().fill(index == page ? T.ink : T.rule)
                        .frame(width: 24, height: 3)
                }
                Spacer()
                Text("\(page + 1) of 3").font(T.mono(11)).foregroundStyle(T.ink2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(page + 1) of 3")
            KPrimaryButton(label: page == 0 ? "Make it yours" : "Choose your models",
                           systemImage: "arrow.right") {
                advance(to: page + 1)
            }
            .accessibilityIdentifier("onboardingContinue")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(T.bg)
    }

    private func advance(to step: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = step }
    }
}
