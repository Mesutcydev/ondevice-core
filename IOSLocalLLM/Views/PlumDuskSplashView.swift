import SwiftUI
import UIKit

/// Cold-start splash — "first light".
///
/// The first frame is exactly `LaunchBackground` (the static launch screen
/// color), so the hand-off from UIKit is seamless. The sequence is one
/// restrained beat built around the mark: the tile settles out of a blur
/// while a soft halo wakes behind it, a single hairline of light sweeps the
/// aperture once, and the wordmark rises into place. Total run ≈ 1.9 s.
///
/// Reduce Motion collapses the sequence to a quiet fade.
struct PlumDuskSplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Entrance flags — each element reads the flag it needs and animates
    // itself, so the beats overlap instead of stepping.
    @State private var appeared = false   // tile + halo + backdrop glow
    @State private var sweepIn = false    // aperture ring: fade in + rotate
    @State private var sweepOut = false   // aperture ring: fade out
    @State private var typed = false      // wordmark
    @State private var dismissing = false // outro

    /// Task-driven beats, seconds from first layout. Per-element delays live
    /// on the elements; these keep the timeline in one place.
    private enum Beat {
        static let sweep = 0.42         // ring starts drawing
        static let haptic = 0.55        // the tile has just settled
        static let type = 0.78          // wordmark rises
        static let sweepFade = 1.16     // ring hands off
        static let outro = 1.55
        static let outroDuration = 0.40
    }

    var body: some View {
        GeometryReader { proxy in
            let markSize = min(proxy.size.width * 0.44, 196)

            ZStack {
                SplashBackdrop(appeared: appeared,
                               dismissing: dismissing,
                               reduceMotion: reduceMotion)

                VStack(spacing: 30) {
                    SplashMark(size: markSize,
                               appeared: appeared,
                               sweepIn: sweepIn,
                               sweepOut: sweepOut,
                               dismissing: dismissing,
                               reduceMotion: reduceMotion)
                        .accessibilityHidden(true)

                    SplashWordmark(typed: typed,
                                   dismissing: dismissing,
                                   reduceMotion: reduceMotion)
                }
                .padding(.horizontal, 24)
                // Sit the mark + type a touch above true center — the classic
                // splash weighting.
                .offset(y: -proxy.size.height * 0.02)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .task { await runEntrance() }
    }

    @MainActor
    private func runEntrance() async {
        appeared = true

        guard !reduceMotion else {
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            typed = true
            try? await Task.sleep(for: .seconds(0.85))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { dismissing = true }
            try? await Task.sleep(for: .seconds(0.32))
            guard !Task.isCancelled else { return }
            onFinished()
            return
        }

        try? await Task.sleep(for: .seconds(Beat.sweep))
        guard !Task.isCancelled else { return }
        sweepIn = true

        // Soft landing tick as the tile reaches its resting size.
        try? await Task.sleep(for: .seconds(Beat.haptic - Beat.sweep))
        guard !Task.isCancelled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)

        try? await Task.sleep(for: .seconds(Beat.type - Beat.haptic))
        guard !Task.isCancelled else { return }
        typed = true

        try? await Task.sleep(for: .seconds(Beat.sweepFade - Beat.type))
        guard !Task.isCancelled else { return }
        sweepOut = true

        try? await Task.sleep(for: .seconds(Beat.outro - Beat.sweepFade))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: Beat.outroDuration)) { dismissing = true }

        try? await Task.sleep(for: .seconds(Beat.outroDuration + 0.05))
        guard !Task.isCancelled else { return }
        onFinished()
    }
}

// MARK: - Backdrop

/// Static base color plus one quiet glow. The base stays put for the whole
/// sequence so the very first frame matches the native launch screen.
private struct SplashBackdrop: View {
    let appeared: Bool
    let dismissing: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack {
                Color("LaunchBackground")

                RadialGradient(
                    colors: [Color.white.opacity(0.80), Color.white.opacity(0)],
                    center: UnitPoint(x: 0.5, y: 0.36),
                    startRadius: 12,
                    endRadius: max(w, h) * 0.60
                )
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.9), value: appeared)

                // Barely-there vignette keeps the weight on the mark.
                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.06)],
                    center: .center,
                    startRadius: min(w, h) * 0.44,
                    endRadius: max(w, h) * 0.80
                )
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.0), value: appeared)
            }
            .opacity(dismissing ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.36), value: dismissing)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Mark

/// The app icon as a free-standing glass tile: a focus-pull settle, one soft
/// halo, and a single hairline of light drawing around the aperture.
private struct SplashMark: View {
    let size: CGFloat
    let appeared: Bool
    let sweepIn: Bool
    let sweepOut: Bool
    let dismissing: Bool
    let reduceMotion: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
    }

    var body: some View {
        ZStack {
            halo
            apertureSweep
            tile
        }
        .frame(width: size, height: size)
    }

    /// Wide, soft light that wakes behind the tile and swells at the outro.
    private var halo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.92),
                        Color(red: 0.64, green: 0.77, blue: 1.00).opacity(0.28),
                        Color.clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.80
                )
            )
            .frame(width: size * 2.0, height: size * 2.0)
            .blur(radius: 34)
            .scaleEffect(appeared ? (dismissing ? 1.06 : 1.0) : 0.72)
            .opacity(appeared ? (dismissing ? 0 : 1) : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.9), value: appeared)
            .animation(.easeInOut(duration: 0.38), value: dismissing)
    }

    /// One hairline of light drawing around the aperture — in, around, gone.
    private var apertureSweep: some View {
        Circle()
            .trim(from: 0.00, to: 0.72)
            .stroke(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: Color.white.opacity(0.10), location: 0.30),
                        .init(color: Color.white.opacity(0.85), location: 0.86),
                        .init(color: Color.white.opacity(0.95), location: 1.00),
                    ]),
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(259)
                ),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
            )
            .frame(width: size * 1.46, height: size * 1.46)
            .rotationEffect(.degrees(sweepIn ? 208 : -52))
            .opacity(sweepOut ? 0 : (sweepIn ? 0.9 : 0))
            .animation(reduceMotion ? nil
                : .timingCurve(0.32, 0.72, 0.24, 1.0, duration: 0.95), value: sweepIn)
            .animation(.easeIn(duration: 0.28), value: sweepOut)
            .blur(radius: 0.3)
            .allowsHitTesting(false)
    }

    private var tile: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            // Slightly overscan so the artwork's own dark surround and baked
            // rim fall outside the mask — the crystal edge below is ours.
            .scaleEffect(1.08)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.70),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.1
                )
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 26, y: 16)
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
            .scaleEffect(appeared ? 1.0 : 0.93)
            .opacity(appeared ? (dismissing ? 0 : 1) : 0)
            .blur(radius: appeared ? (dismissing ? 6 : 0) : 14)
            .offset(y: appeared ? 0 : 10)
            .animation(reduceMotion ? nil
                : .spring(response: 0.62, dampingFraction: 0.86).delay(0.04),
                value: appeared)
            .animation(.easeInOut(duration: 0.38), value: dismissing)
    }
}

// MARK: - Wordmark

/// Title and tagline rising into place — a blur-out and settle rather than a
/// masked reveal. Type is pinned to the system faces instead of the theme
/// helpers: those probe for an optional custom family and fall back to
/// `Font.custom` with a generated system name, a path whose result varies by
/// build. The explicit faces keep the splash deterministic and match the
/// app's rendered chrome.
private struct SplashWordmark: View {
    let typed: Bool
    let dismissing: Bool
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 11) {
            Text("OnDevice Core")
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.6)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(white: 0.10), Color(white: 0.32)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(typed ? 1 : 0)
                .blur(radius: typed ? 0 : 5)
                .offset(y: typed ? 0 : 7)
                .animation(reduceMotion ? nil
                    : .easeOut(duration: 0.5).delay(0.02),
                    value: typed)

            Text("LOCAL AI STUDIO")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                // Letters condense into place as the line arrives.
                .tracking(typed ? 3.0 : 5.4)
                // Balance the tracking that trails the last glyph so the line
                // stays optically centered.
                .padding(.leading, typed ? 3.0 : 5.4)
                .foregroundStyle(Color(white: 0.42))
                .opacity(typed ? 1 : 0)
                .blur(radius: typed ? 0 : 4)
                .offset(y: typed ? 0 : 5)
                .animation(reduceMotion ? nil
                    : .easeOut(duration: 0.55).delay(0.12),
                    value: typed)
        }
        .multilineTextAlignment(.center)
        .opacity(dismissing ? 0 : 1)
        .offset(y: dismissing ? -5 : 0)
        .animation(.easeInOut(duration: 0.26), value: dismissing)
        .accessibilityElement(children: .combine)
    }
}
