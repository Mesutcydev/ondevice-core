import SwiftUI
import OnDeviceUI

/// Launch interstitial shown over the workbench's first frame.
///
/// Design contract (2026-09-22 device report — the previous version read as
/// misaligned and low quality):
/// - The wordmark is centered on the **screen**, not the safe area. Centering
///   inside the safe area puts the optically-weighted point visibly low on
///   Dynamic Island phones.
/// - The background is the page canvas, and `LaunchBackground` in the asset
///   catalog carries the same values, so system launch screen → splash reads
///   as one continuous surface (no color jump).
/// - The splash holds for a minimum readable beat instead of dismissing on
///   the same runloop it appears, which looked like a render glitch.
struct BootSplashView: View {
    let onFinished: () -> Void

    /// Minimum time the wordmark stays up. Long enough to read as an
    /// intentional launch moment, short enough to never feel like a gate.
    private static let minimumHold: Duration = .milliseconds(850)

    var body: some View {
        ODPageBackground()
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: ODLayout.labelGap) {
                    Text("OnDevice")
                        .font(.system(.largeTitle, design: .serif).weight(.semibold))
                        .foregroundStyle(ODPalette.text)
                    Text("LOCAL AI WORKBENCH")
                        .font(.footnote.weight(.medium))
                        .tracking(2.5)
                        .foregroundStyle(ODPalette.secondary)
                }
                // Optical lift: a truly centered lockup reads as sinking
                // because the wordmark has no descenders below baseline.
                .offset(y: -ODLayout.pageInset)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("OnDevice")
            .task {
                try? await Task.sleep(for: Self.minimumHold)
                guard !Task.isCancelled else { return }
                onFinished()
            }
    }
}
