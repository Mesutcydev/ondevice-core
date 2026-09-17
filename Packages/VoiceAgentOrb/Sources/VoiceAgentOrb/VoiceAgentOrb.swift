import QuartzCore
import SwiftUI

/// A premium voice-agent orb for local AI voice sessions.
///
/// The orb is a pure rendering component: it does not own voice-session
/// logic. Drive it with your pipeline's state and the normalized audio
/// levels from ``VoiceOrbAudioModel``:
///
/// ```swift
/// VoiceAgentOrb(
///     state: session.state,
///     microphoneLevel: audioModel.microphoneLevel,
///     outputLevel: audioModel.outputLevel
/// )
/// ```
///
/// Rendering: two `Canvas` surfaces (interior + glass shell) driven by a
/// single display-synchronised clock through ``VoiceOrbAnimationCoordinator``.
/// The animation clock pauses while the scene is inactive.
///
/// The interior refraction shader in `Shaders/VoiceOrbShaders.metal` is *not*
/// applied by this package: SwiftPM does not compile `[[stitchable]]` shaders
/// into `ShaderLibrary.bundle` the way an Xcode app target does. Adopters that
/// want the light-bend add the file to their own target and apply
/// `ShaderLibrary.voiceOrbRefraction` to the orb; every visual layer has a
/// non-Metal fallback, so the orb renders identically structured without it.
public struct VoiceAgentOrb: View {

    public let state: VoiceOrbState
    public let microphoneLevel: CGFloat
    public let outputLevel: CGFloat
    public let speechActivity: CGFloat
    public let theme: VoiceAgentOrbTheme
    /// Overall layout box; the orb itself occupies ~62% of it, the rest is
    /// reserved for glow and the contact shadow.
    public let size: CGFloat
    public let showsStatusLabel: Bool
    /// Forces a render quality (previews/tests). `nil` = automatic policy.
    public let qualityOverride: VoiceOrbRenderQuality?
    public let accessibilityLabelOverride: String?
    /// Optional per-frame level sampler. When set, the orb's single render
    /// clock reads levels here — hosts must not wrap another clock.
    public let levelSampler: (() -> (microphone: CGFloat, output: CGFloat, speechActivity: CGFloat))?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var coordinator = VoiceOrbAnimationCoordinator()
    @StateObject private var performancePolicy = VoiceOrbPerformancePolicy()
    @StateObject private var renderClock = VoiceAgentOrbRenderClock()
    @State private var paletteCache = VoiceOrbPaletteCacheReference()
    @State private var haptics = VoiceOrbHaptics()
    @State private var lastHandledKind: VoiceOrbStateKind?
    @State private var isVisible = false

    public init(
        state: VoiceOrbState,
        microphoneLevel: CGFloat = 0,
        outputLevel: CGFloat = 0,
        speechActivity: CGFloat = 0,
        theme: VoiceAgentOrbTheme = .default,
        size: CGFloat = 220,
        showsStatusLabel: Bool = true,
        qualityOverride: VoiceOrbRenderQuality? = nil,
        accessibilityLabel: String? = nil,
        levelSampler: (() -> (microphone: CGFloat, output: CGFloat, speechActivity: CGFloat))? = nil
    ) {
        self.state = state
        self.microphoneLevel = microphoneLevel
        self.outputLevel = outputLevel
        self.speechActivity = speechActivity
        self.theme = theme
        self.size = size
        self.showsStatusLabel = showsStatusLabel
        self.qualityOverride = qualityOverride
        self.accessibilityLabelOverride = accessibilityLabel
        self.levelSampler = levelSampler
    }

    private var effectiveQuality: VoiceOrbRenderQuality {
        qualityOverride ?? performancePolicy.quality
    }

    public var body: some View {
        VStack(spacing: size * 0.02) {
            Group {
                let now = renderClock.date.timeIntervalSinceReferenceDate
                let levels = sampledLevels()
                let snapshot = coordinator.snapshot(
                    at: now,
                    microphoneLevel: Double(levels.microphone),
                    outputLevel: Double(levels.output),
                    speechActivity: Double(levels.speechActivity)
                )
                orbSurfaces(snapshot: snapshot, now: now)
            }
            .frame(width: size, height: size)

            if showsStatusLabel {
                Text(VoiceOrbAccessibility.statusText(for: state))
                    .font(.callout)
                    .foregroundStyle(theme.labelColor?.resolve(in: colorScheme) ?? .secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: VoiceOrbAccessibility.statusText(for: state))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelOverride ?? VoiceOrbAccessibility.label(for: state))
        .onAppear {
            isVisible = true
            haptics.prepare()
            performancePolicy.sceneIsActive = scenePhase == .active
            performancePolicy.reduceMotion = reduceMotion
            coordinator.setReducedMotion(reduceMotion, now: Self.clockNow())
            coordinator.setState(state, now: Self.clockNow())
            lastHandledKind = state.kind
            updateRenderClock()
        }
        .onChange(of: state) { _, newState in
            handleStateChange(newState)
        }
        .onChange(of: reduceMotion) { _, flag in
            performancePolicy.reduceMotion = flag
            coordinator.setReducedMotion(flag, now: Self.clockNow())
            updateRenderClock()
        }
        .onChange(of: scenePhase) { _, phase in
            performancePolicy.sceneIsActive = isVisible && phase == .active
            updateRenderClock()
        }
        .onChange(of: effectiveQuality) { _, _ in
            updateRenderClock()
        }
        .onDisappear {
            isVisible = false
            performancePolicy.sceneIsActive = false
            renderClock.stop()
        }
    }

    private func sampledLevels() -> (microphone: CGFloat, output: CGFloat, speechActivity: CGFloat) {
        if let levelSampler {
            return levelSampler()
        }
        return (microphoneLevel, outputLevel, speechActivity)
    }

    // MARK: Surfaces

    @ViewBuilder
    private func orbSurfaces(snapshot: VoiceOrbFrameSnapshot, now: Double) -> some View {
        let blend = coordinator.paletteBlend(at: now)
        let colors = paletteCache.blend(
            from: blend.from, to: blend.to, t: blend.t,
            theme: theme, colorScheme: colorScheme
        )
        let quality = effectiveQuality

        ZStack {
            // Interior: volume, energy, core, particles, waves.
            // Hosts that ship `Shaders/VoiceOrbShaders.metal` in their own
            // target can apply `voiceOrbRefraction` to this surface only; the
            // shell stays undistorted so the glass edge remains crisp.
            Canvas { context, canvasSize in
                var ctx = context
                VoiceOrbRenderer.drawInterior(
                    context: &ctx, size: canvasSize,
                    snapshot: snapshot, colors: colors, quality: quality
                )
            }

            // Shell: shadow, glow, glass, rim, fringe, progress ring.
            Canvas { context, canvasSize in
                var ctx = context
                VoiceOrbRenderer.drawShell(
                    context: &ctx, size: canvasSize,
                    snapshot: snapshot, colors: colors, quality: quality
                )
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: State changes

    private func handleStateChange(_ newState: VoiceOrbState) {
        let now = Self.clockNow()
        let signpost = VoiceOrbSignpost.begin("StateChangeToRender")
        coordinator.setState(newState, now: now)
        if reduceMotion { renderClock.refreshStaticFrame() }
        VoiceOrbSignpost.end("StateChangeToRender", signpost)

        // Haptics and announcements fire once per *kind*, never per frame or
        // per associated-value update (e.g. preparing progress ticks).
        guard newState.kind != lastHandledKind else { return }
        lastHandledKind = newState.kind
        VoiceOrbAccessibility.announceIfNeeded(for: newState)
        haptics.fire(for: newState.kind)
    }

    private static func clockNow() -> Double {
        Date().timeIntervalSinceReferenceDate
    }

    private func updateRenderClock() {
        renderClock.configure(
            interval: effectiveQuality.minimumFrameInterval ?? (1.0 / 30.0),
            active: isVisible && scenePhase == .active && !reduceMotion
        )
        if reduceMotion { renderClock.refreshStaticFrame() }
    }
}

/// Reference storage keeps the renderer's resolved-color cache out of
/// SwiftUI's value-type `@State` mutation tracking. The cache is intentionally
/// non-observable: refreshing it must never invalidate a frame by itself.
@MainActor
private final class VoiceOrbPaletteCacheReference {
    private var cache = VoiceOrbPaletteCache()

    func blend(
        from: VoiceOrbStateKind,
        to: VoiceOrbStateKind,
        t: Double,
        theme: VoiceAgentOrbTheme,
        colorScheme: ColorScheme
    ) -> VoiceOrbBlendedPalette {
        cache.blend(
            from: from,
            to: to,
            t: t,
            theme: theme,
            colorScheme: colorScheme
        )
    }
}

/// Exact display-rate divisor for smooth motion on 120 Hz ProMotion panels.
/// `TimelineView.minimumInterval` may produce uneven frame spacing because it
/// is a lower bound rather than a requested presentation cadence.
@MainActor
private final class VoiceAgentOrbRenderClock: ObservableObject {
    @Published private(set) var date = Date()

    #if os(macOS)
    nonisolated(unsafe) private var timer: Timer?
    #else
    nonisolated(unsafe) private var displayLink: CADisplayLink?
    #endif
    private var interval = 1.0 / 30.0
    private var isActive = false
    private var pendingFrame: Task<Void, Never>?
    private var latestFrameDate = Date()
    private var referenceTimeOffset = Date().timeIntervalSinceReferenceDate - CACurrentMediaTime()

    func configure(interval: Double, active: Bool) {
        let intervalChanged = abs(self.interval - interval) > .ulpOfOne
        self.interval = interval
        isActive = active
        guard active else {
            stopLink()
            return
        }

        #if os(macOS)
        if intervalChanged {
            stopLink()
        }
        if timer == nil {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.date = Date()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        #else
        referenceTimeOffset = Date().timeIntervalSinceReferenceDate - CACurrentMediaTime()
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        applyFrameRate()
        #endif
    }

    func refreshStaticFrame() { date = Date() }

    func stop() {
        isActive = false
        stopLink()
    }

    private func applyFrameRate() {
        #if !os(macOS)
        let fps = Float(max(1, Int((1 / interval).rounded())))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: fps,
            maximum: fps,
            preferred: fps
        )
        #endif
    }

    private func stopLink() {
        pendingFrame?.cancel()
        pendingFrame = nil
        #if os(macOS)
        timer?.invalidate()
        timer = nil
        #else
        displayLink?.invalidate()
        displayLink = nil
        #endif
    }

    #if !os(macOS)
    @objc private func tick(_ link: CADisplayLink) {
        guard isActive else { return }
        latestFrameDate = Date(
            timeIntervalSinceReferenceDate: link.targetTimestamp + referenceTimeOffset
        )
        // Coalesce while SwiftUI is busy. At most one deferred publication
        // exists, and it always uses the newest frame rather than replaying
        // an accumulated queue of obsolete timestamps after a stall.
        guard pendingFrame == nil else { return }
        pendingFrame = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pendingFrame = nil
            guard self.isActive else { return }
            self.date = self.latestFrameDate
        }
    }
    #endif

    deinit {
        #if os(macOS)
        timer?.invalidate()
        #else
        displayLink?.invalidate()
        #endif
    }
}
