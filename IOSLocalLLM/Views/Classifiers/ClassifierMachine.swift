// Adapted from the owner-supplied Token AI Classifier, App/Design/Machine.swift.
// Geometry, materials and motion timings are preserved. See Docs/CLASSIFIER_PRINT_INTEGRATION.md.
import SwiftUI
import OnDeviceUI

/// What the machine is doing. Each mood maps to a real workspace state, so
/// the face reports status, not decoration.
enum ClassifierMachineMood: Equatable {
    /// No model loaded: eyes shut, rim dimmed.
    case asleep
    /// Loading a model: eyes opening.
    case waking
    /// Ready: eyes open, an occasional blink.
    case awake
    /// Classifying: eyes scan, the mouth glows.
    case reading
    /// The last operation failed: a lopsided squint and a shake.
    case puzzled

    var accessibilityValue: String {
        switch self {
        case .asleep: return String(localized: "Asleep. No model loaded.")
        case .waking: return String(localized: "Loading the model.")
        case .awake: return String(localized: "Ready.")
        case .reading: return String(localized: "Classifying.")
        case .puzzled: return String(localized: "Something went wrong.")
        }
    }
}

/// The mascot from the app icon, drawn in code so its eyes and mouth can
/// respond to the workspace. Laid out on a 160 × 140 grid and scaled to `width`.
struct ClassifierMachine: View {
    var mood: ClassifierMachineMood
    var width: CGFloat = 160
    /// Eyes glance down toward the input while the user types.
    var isWatching = false
    /// Change to make the machine squint happily (a result landed, a tap).
    var reaction = 0

    @State private var isBlinking = false
    @State private var isSquinting = false
    @State private var shakes: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.odWorkspaceVisible) private var workspaceVisible
    @Environment(\.scenePhase) private var scenePhase

    static let aspect: CGFloat = 140 / 160
    /// Vertical centre of the mouth, as a fraction of height. A ticket's top
    /// edge is aligned here so it reads as coming out of the slot.
    static let mouthCenter: CGFloat = 97 / 140
    static let mouthWidth: CGFloat = 108 / 160

    static let rim = LinearGradient(
        colors: [
            Color(red: 0.98, green: 0.82, blue: 0.68),
            Color(red: 0.80, green: 0.52, blue: 0.34),
            Color(red: 0.48, green: 0.26, blue: 0.15)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private var s: CGFloat { width / 160 }
    private var animates: Bool { workspaceVisible && scenePhase == .active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: mood != .reading || !animates)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let scanning = mood == .reading && animates
            face(
                gazeX: scanning ? sin(t * 4.2) * 7 : 0,
                glow: scanning ? 0.45 + 0.35 * sin(t * 7) : (mood == .reading ? 0.6 : 0)
            )
        }
        .frame(width: width, height: width * Self.aspect)
        .modifier(ClassifierMachineShake(phase: shakes, amplitude: 6 * s))
        .rotationEffect(.degrees(mood == .puzzled ? -4 : 0))
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.58), value: mood)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isWatching)
        .task(id: animates && mood == .awake) { await blinkWhileAwake() }
        .onChange(of: mood) { _, mood in
            guard mood == .puzzled, animates else { return }
            withAnimation(.linear(duration: 0.45)) { shakes += 1 }
        }
        .task(id: reaction) { if reaction > 0 && animates { await squint() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Classifier")
        .accessibilityValue(mood.accessibilityValue)
    }

    // MARK: Face

    private func face(gazeX: Double, glow: Double) -> some View {
        ZStack {
            // Extruded depth, as on the icon.
            RoundedRectangle(cornerRadius: 40 * s, style: .continuous)
                .fill(Color(red: 0.07, green: 0.06, blue: 0.055))
                .offset(x: 5 * s, y: 7 * s)
                .shadow(color: .black.opacity(0.28), radius: 16 * s, y: 12 * s)

            RoundedRectangle(cornerRadius: 40 * s, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.40, green: 0.38, blue: 0.36),
                        Color(red: 0.24, green: 0.23, blue: 0.22),
                        Color(red: 0.16, green: 0.15, blue: 0.14)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: 40 * s, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center),
                            lineWidth: 1.2 * s
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 34 * s, style: .continuous)
                        .strokeBorder(Self.rim, lineWidth: 2.2 * s)
                        .padding(5 * s)
                        .opacity(mood == .asleep ? 0.45 : 1)
                }

            HStack(spacing: 44 * s) {
                eye(openness: openness(right: false))
                eye(openness: openness(right: true))
            }
            .offset(x: gazeX * s, y: (isWatching && mood == .awake ? -16 : -22) * s)

            mouth(glow: glow)
                .offset(y: 27 * s)
        }
    }

    private func openness(right: Bool) -> CGFloat {
        if isBlinking { return 0.08 }
        switch mood {
        case .asleep: return 0.1
        case .waking: return 0.45
        case .awake: return isSquinting ? 0.42 : 1
        case .reading: return 0.82
        case .puzzled: return right ? 0.5 : 1
        }
    }

    private func eye(openness: CGFloat) -> some View {
        Ellipse()
            .fill(LinearGradient(
                colors: [Color(white: 0.02), Color(white: 0.12)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay {
                // A recessed socket: dark upper lip, lit lower lip.
                Ellipse().strokeBorder(
                    LinearGradient(colors: [.black.opacity(0.7), .white.opacity(0.3)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.3 * s
                )
            }
            .overlay(alignment: .topLeading) {
                Ellipse()
                    .fill(.white.opacity(0.22))
                    .frame(width: 5 * s, height: 9 * s)
                    .offset(x: 5 * s, y: 6 * s)
            }
            .frame(width: 21 * s, height: 36 * s)
            .scaleEffect(x: 1, y: openness, anchor: .center)
    }

    private func mouth(glow: Double) -> some View {
        Capsule()
            .fill(Color(red: 0.035, green: 0.03, blue: 0.028))
            .overlay {
                Capsule()
                    .fill(ClassifierPrintStyle.signalFill)
                    .padding(.horizontal, 10 * s)
                    .padding(.vertical, 5 * s)
                    .blur(radius: 4 * s)
                    .opacity(glow)
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [.black.opacity(0.8), .white.opacity(0.22)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.3 * s
                )
            }
            .frame(width: Self.mouthWidth * width, height: 18 * s)
    }

    // MARK: Behaviour

    private func blinkWhileAwake() async {
        defer { isBlinking = false }
        guard mood == .awake, animates else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 2_200...5_200)))
            guard !Task.isCancelled else { return }
            let double = Int.random(in: 0..<5) == 0
            for _ in 0..<(double ? 2 : 1) {
                withAnimation(.easeIn(duration: 0.06)) { isBlinking = true }
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeOut(duration: 0.12)) { isBlinking = false }
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }

    private func squint() async {
        guard mood == .awake, animates else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { isSquinting = true }
        do { try await Task.sleep(for: .milliseconds(650)) } catch { isSquinting = false; return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { isSquinting = false }
    }
}

/// A short horizontal shake; `phase` advancing by 1 plays it once.
private struct ClassifierMachineShake: GeometryEffect {
    var phase: CGFloat
    var amplitude: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amplitude * sin(phase * .pi * 6), y: 0))
    }
}
