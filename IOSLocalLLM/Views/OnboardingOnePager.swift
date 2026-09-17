import SwiftUI

// MARK: - OnboardingOnePager
//
// Single-page first-run brief. Replaces the retired multi-page tour with one
// page: a README-style capability table (runtime → what it powers), the
// privacy statement in plain words, and a single primary action.
//
// Deliberately service-free (design layer + backdrop only), so the
// DesignReview simulator harness compiles this file verbatim and shows the
// exact same pixels the app renders on device.

struct OnboardingOnePager: View {
    @Environment(\.koduTheme) private var T
    /// Called when the user taps through — the caller records
    /// `hasSeenOnboarding` and closes the cover.
    var onFinish: () -> Void

    var body: some View {
        let S = T.studio
        return ZStack {
            StudioPageBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StudioMonoLabel(text: "OnDevice Max · first run", size: 11, tracking: 0.9)
                        .padding(.top, 16)

                    Text("This iPhone runs\nthe models.")
                        .font(S.sans(34, .semibold))
                        .tracking(-1.0)
                        .lineSpacing(3)
                        .foregroundStyle(S.ink)
                        .padding(.top, 14)

                    Text("Assistant, camera, voice, and image generation all execute on this device. Conversations, camera frames, and files are processed here — nothing is uploaded.")
                        .font(S.sans(15))
                        .lineSpacing(6.5)
                        .foregroundStyle(S.ink2)
                        .padding(.top, 12)
                        .fixedSize(horizontal: false, vertical: true)

                    StudioHairline(color: S.rule2)
                        .padding(.top, 22)

                    StudioMonoLabel(text: "Runtimes", size: 11, tracking: 0.9)
                        .padding(.top, 22)
                    CapabilityTable(rows: [
                        ("MLX", "Apple-silicon chat and vision — Qwen 3, Gemma, and imported models"),
                        ("GGUF", "Quantized community models, llama.cpp format"),
                        ("Core AI", "Apple's on-device model packs — detection, segmentation, depth"),
                        ("Core ML", "FastVLM vision pipeline and Whisper dictation"),
                        ("Stable Diffusion", "Text-to-image generation, run locally"),
                    ])
                    .padding(.top, 12)

                    StudioMonoLabel(text: "Capabilities", size: 11, tracking: 0.9)
                        .padding(.top, 28)
                    CapabilityTable(rows: [
                        ("Assistant", "Code and chat with on-device memory and tool use"),
                        ("Lens", "Camera OCR, live translation, text and object capture"),
                        ("Voice", "Kitten speech synthesis; live dictation in both modes"),
                        ("Library", "Search, download, import, and swap models offline"),
                        ("RAG", "Local embeddings answer questions about your files"),
                        ("Share", "Send text and images in from any app"),
                        ("Mac bridge", "Hand a task to a paired Mac over your network"),
                        ("Local API", "OpenAI-compatible endpoint served by this phone"),
                    ])
                    .padding(.top, 12)

                    StudioHairline(color: S.rule2)
                        .padding(.top, 24)
                    Text("Network access is used only for model downloads and optional web search. No account, no telemetry.")
                        .font(T.mono(11))
                        .foregroundStyle(S.ink3)
                        .padding(.top, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, StudioSpacing.xl)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                StudioHairline(color: T.studio.rule2)
                StudioPrimaryButton(title: "Start using Max") {
                    HapticManager.impact(.medium)
                    onFinish()
                }
                .padding(.horizontal, StudioSpacing.xl)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .background(T.studio.paper)
        }
    }
}

// MARK: - README-style capability table

/// GitHub-README-style table: monospace keys in a fixed column, plain-language
/// values, hairline rules between rows — no boxes, no tinted fills.
private struct CapabilityTable: View {
    @Environment(\.koduTheme) private var T
    let rows: [(String, String)]

    var body: some View {
        let S = T.studio
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 {
                    StudioHairline(color: S.rule2)
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(row.0)
                        .font(T.mono(11.5, .semibold))
                        .tracking(0.2)
                        .foregroundStyle(S.ink)
                        .frame(width: 108, alignment: .leading)
                    Text(row.1)
                        .font(S.sans(13))
                        .lineSpacing(5)
                        .foregroundStyle(S.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
            }
        }
    }
}
