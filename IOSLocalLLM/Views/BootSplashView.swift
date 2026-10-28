import SwiftUI
import OnDeviceUI

/// Launch interstitial shown over the workbench's first frame.
///
/// Design contract (2026-09-22 device report — the previous version read as
/// misaligned and low quality):
/// - The wordmark is centered on the **screen**, not the safe area. Centering
///   inside the safe area puts the optically-weighted point visibly low on
///   Dynamic Island phones.
/// - The background is the app icon's ink plate, and `LaunchBackground` in the
///   asset catalog carries the same value, so icon → launch screen → splash
///   reads as one continuous surface (no color jump).
/// - The splash holds for a minimum readable beat instead of dismissing on
///   the same runloop it appears, which looked like a render glitch.
struct BootSplashView: View {
    let onFinished: () -> Void

    /// Minimum time the lockup stays up: the mark traces in (0.8 s) and one
    /// token stream starts along it. Short enough to never feel like a gate.
    private static let minimumHold: Duration = .milliseconds(1600)

    var body: some View {
        Color(red: 0.043, green: 0.047, blue: 0.063)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: ODLayout.labelGap) {
                    // The icon carries straight into the app: same plate, mark traced in.
                    ODBrandMark(height: 44, motion: .intro)
                        .padding(.bottom, ODLayout.largeGap)
                    // Sans bold, matching the App Store artwork's lockup.
                    Text("Token AI")
                        .font(.largeTitle.weight(.bold))
                    Text("LOCAL AI STUDIO")
                        .font(.footnote.weight(.medium))
                        .tracking(2.5)
                        .opacity(0.6)
                }
                .foregroundStyle(.white)
                // Optical lift: a truly centered lockup reads as sinking
                // because the wordmark has no descenders below baseline.
                .offset(y: -ODLayout.pageInset)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Token AI")
            .task {
                try? await Task.sleep(for: Self.minimumHold)
                guard !Task.isCancelled else { return }
                onFinished()
            }
    }
}
