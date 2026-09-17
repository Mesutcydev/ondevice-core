import SwiftUI
import UIKit

/// Cold-start splash.
///
/// The first frame is exactly `LaunchBackground` — the same color as the
/// static launch screen — so the hand-off from UIKit is seamless. Everything
/// after that is one choreographed entrance: ambient light blooms behind the
/// glass mark, the mark resolves out of a blur and catches a single specular
/// sweep, a soft ring carries outward from the iris, and the wordmark is
/// revealed behind a translating mask.
///
/// Each element owns its curve and delay, so the beats overlap instead of
/// stepping. The sequence runs ~2.2 s, then the splash dissolves its own
/// layers before calling `onFinished`. Reduce Motion collapses everything to
/// a short cross-fade.
struct PlumDuskSplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Phase flags — flipped once from `runEntrance`; every element reads the
    // flag it needs and animates itself.
    @State private var appeared = false
    @State private var pulse = false
    @State private var sheen = false
    @State private var breathing = false
    @State private var drifting = false
    @State private var dismissing = false

    /// Task-driven beats, in seconds from first layout. The per-element
    /// delays live on the elements themselves; these two only need the
    /// timeline. Kept together so the choreography can be retimed in one
    /// place.
    private enum Beat {
        static let haptic = 0.52        // the tile has just settled
        static let outro = 1.78
        static let outroDuration = 0.45
    }

    var body: some View {
        GeometryReader { proxy in
            let markSize = min(proxy.size.width * 0.44, 196)

            ZStack {
                SplashBackdrop(appeared: appeared,
                               drifting: drifting,
                               reduceMotion: reduceMotion)
                    .opacity(dismissing ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4),
                               value: dismissing)

                VStack(spacing: 30) {
                    SplashMark(size: markSize,
                               appeared: appeared,
                               pulse: pulse,
                               sheen: sheen,
                               breathing: breathing,
                               dismissing: dismissing,
                               reduceMotion: reduceMotion)
                        .accessibilityHidden(true)

                    SplashWordmark(appeared: appeared,
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
        pulse = true
        sheen = true

        guard !reduceMotion else {
            breathing = true
            drifting = true
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { dismissing = true }
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            onFinished()
            return
        }

        // Soft landing tick as the tile reaches its resting size.
        try? await Task.sleep(for: .seconds(Beat.haptic))
        guard !Task.isCancelled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)

        // Let the entrance resolve before the ambient layers start moving so
        // the two never fight over the same transform.
        try? await Task.sleep(for: .seconds(0.45))
        guard !Task.isCancelled else { return }
        breathing = true
        drifting = true

        try? await Task.sleep(for: .seconds(Beat.outro - Beat.haptic - 0.45))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: Beat.outroDuration)) { dismissing = true }

        try? await Task.sleep(for: .seconds(Beat.outroDuration + 0.05))
        guard !Task.isCancelled else { return }
        onFinished()
    }
}

// MARK: - Backdrop

/// Static base color + light that wakes up behind the mark. The base stays
/// put for the whole sequence so the very first frame matches the native
/// launch screen.
private struct SplashBackdrop: View {
    let appeared: Bool
    let drifting: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack {
                Color("LaunchBackground")

                RadialGradient(
                    colors: [Color.white.opacity(0.85), Color.white.opacity(0)],
                    center: UnitPoint(x: 0.5, y: 0.34),
                    startRadius: 10,
                    endRadius: max(w, h) * 0.62
                )
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.0), value: appeared)

                Circle()
                    .fill(Color(red: 0.50, green: 0.68, blue: 1.00).opacity(0.16))
                    .frame(width: w * 0.95)
                    .blur(radius: 42)
                    .offset(x: -w * 0.38, y: -h * 0.24 + (drifting ? 14 : -14))
                    .opacity(appeared ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.1), value: appeared)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 6.5)
                        .repeatForever(autoreverses: true), value: drifting)

                Circle()
                    .fill(Color(red: 0.56, green: 0.83, blue: 0.74).opacity(0.14))
                    .frame(width: w * 0.85)
                    .blur(radius: 48)
                    .offset(x: w * 0.42, y: h * 0.08 + (drifting ? -16 : 16))
                    .opacity(appeared ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: appeared)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 7.5)
                        .repeatForever(autoreverses: true), value: drifting)

                RoundedRectangle(cornerRadius: 64, style: .continuous)
                    .fill(Color(red: 0.72, green: 0.62, blue: 0.96).opacity(0.07))
                    .frame(width: w * 1.15, height: h * 0.34)
                    .rotationEffect(.degrees(-18))
                    .blur(radius: 54)
                    .offset(x: w * 0.18, y: h * 0.40)
                    .opacity(appeared ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.3), value: appeared)

                // Gentle vignette keeps the weight on the mark.
                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.07)],
                    center: .center,
                    startRadius: min(w, h) * 0.42,
                    endRadius: max(w, h) * 0.78
                )
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: appeared)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Mark

/// The app icon as a free-standing glass tile: focus-pull entrance, one
/// specular pass, iris rings, then a slow breath while the wordmark arrives.
private struct SplashMark: View {
    let size: CGFloat
    let appeared: Bool
    let pulse: Bool
    let sheen: Bool
    let breathing: Bool
    let dismissing: Bool
    let reduceMotion: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
    }

    var body: some View {
        ZStack {
            // Bloom: swells in ahead of the tile, then settles into a halo.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color(red: 0.62, green: 0.76, blue: 1.00).opacity(0.35),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.72
                    )
                )
                .frame(width: size * 1.8, height: size * 1.8)
                .blur(radius: 30)
                .scaleEffect(appeared ? (breathing ? 1.03 : 1.0) : 0.58)
                .opacity(appeared ? (dismissing ? 0 : 1) : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.85), value: appeared)
                .animation(reduceMotion ? nil : .easeInOut(duration: 2.8)
                    .repeatForever(autoreverses: true), value: breathing)
                .animation(.easeInOut(duration: 0.4), value: dismissing)

            tile
        }
        .frame(width: size, height: size)
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
                ZStack {
                    sheenLayer
                    irisRings
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color.white.opacity(0.20),
                            Color.white.opacity(0.75),
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
            .scaleEffect(appeared ? (breathing ? 1.012 : 1.0) : 0.88)
            .opacity(appeared ? (dismissing ? 0 : 1) : 0)
            .blur(radius: appeared ? (dismissing ? 7 : 0) : 22)
            .offset(y: appeared ? 0 : 12)
            .rotation3DEffect(.degrees(appeared ? 0 : 7),
                              axis: (x: 1, y: 0, z: 0),
                              perspective: 0.55)
            .animation(reduceMotion ? nil
                : .spring(response: 0.9, dampingFraction: 0.78).delay(0.06),
                value: appeared)
            .animation(reduceMotion ? nil : .easeInOut(duration: 2.8)
                .repeatForever(autoreverses: true), value: breathing)
            .animation(.easeInOut(duration: 0.45), value: dismissing)
    }

    /// A single diagonal band of light crossing the glass.
    private var sheenLayer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .white.opacity(0.0), location: 0.18),
                    .init(color: .white.opacity(0.55), location: 0.50),
                    .init(color: .white.opacity(0.0), location: 0.82),
                    .init(color: .clear, location: 1.00),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: w * 0.45, height: geo.size.height * 1.8)
            .rotationEffect(.degrees(24))
            .blur(radius: 2)
            .offset(x: sheen ? w * 1.6 : -w * 1.6)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.15).delay(0.50),
                       value: sheen)
            .blendMode(.screen)
            .frame(width: w, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    /// Two soft rings carried outward from the iris.
    private var irisRings: some View {
        ZStack {
            irisRing(delay: 0)
            irisRing(delay: 0.14)
        }
    }

    private func irisRing(delay: Double) -> some View {
        Circle()
            .strokeBorder(Color.white.opacity(0.7), lineWidth: 1.1)
            .frame(width: size * 0.46, height: size * 0.46)
            .scaleEffect(pulse ? 2.2 : 0.5)
            .opacity(pulse ? 0 : 1)
            .blur(radius: 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 1.35).delay(0.45 + delay),
                       value: pulse)
    }
}

// MARK: - Wordmark

/// Title and tagline revealed behind a feathered mask that opens from the
/// center — an "unrolling" reveal rather than a plain fade.
///
/// Type is pinned to the system faces instead of the theme helpers: those
/// probe for an optional custom family and fall back to `Font.custom` with a
/// generated system name, a path whose result varies by build. The explicit
/// faces keep the splash deterministic and match the app's rendered chrome.
private struct SplashWordmark: View {
    let appeared: Bool
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
                .mask { CenterReveal(progress: appeared ? 1 : 0) }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(reduceMotion ? nil
                    : .easeOut(duration: 0.6).delay(0.78),
                    value: appeared)

            Text("LOCAL AI STUDIO")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                // Letters condense into place as the line reveals.
                .tracking(appeared ? 4.0 : 9.0)
                // Balance the tracking that trails the last glyph so the line
                // stays optically centered.
                .padding(.leading, appeared ? 4.0 : 9.0)
                .foregroundStyle(Color(white: 0.42))
                .mask { CenterReveal(progress: appeared ? 1 : 0) }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 7)
                .animation(reduceMotion ? nil
                    : .easeOut(duration: 0.6).delay(0.95),
                    value: appeared)
        }
        .multilineTextAlignment(.center)
        .opacity(dismissing ? 0 : 1)
        .offset(y: dismissing ? -6 : 0)
        .animation(.easeInOut(duration: 0.28), value: dismissing)
        .accessibilityElement(children: .combine)
    }
}

/// Opens from the center outward behind a soft vertical edge. The revealed
/// band is deliberately wider than the content at rest so the feathered edge
/// always clears the first and last glyph.
private struct CenterReveal: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .frame(width: max(geo.size.width * 1.6 * progress, 0.01),
                           height: geo.size.height + 28)
                    .blur(radius: 7)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}
