import Combine
import MetalKit
import SwiftUI
import VoiceAgentOrb

// Aperture: an original, continuous ribbon sculpture. SwiftUI owns semantic
// state; Metal owns motion and audio sampling, without publishing each frame.
struct VoiceActivityOrb: View {
    let phase: VoiceSessionPhase
    let micLevel: Float
    let reduceMotion: Bool
    var renderingMode: VoiceRenderingMode = .automatic
    var samplesLiveAudio = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    var body: some View {
        ApertureMetalSurface(configuration: ApertureConfiguration(
            mode: ApertureOrbMode(phase: phase),
            dark: colorScheme == .dark,
            reduceMotion: reduceMotion,
            reducedQuality: renderingMode == .reduced,
            fallbackLevel: micLevel,
            samplesLiveAudio: samplesLiveAudio,
            active: visible && scenePhase == .active
        ))
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("voiceOrb")
        .accessibilityLabel(phase.statusLabel)
    }
}

struct VoiceStatusLabel: View {
    let phase: VoiceSessionPhase
    let detail: String?
    @Environment(\.koduTheme) private var theme

    var body: some View {
        VStack(spacing: 5) {
            Text(phase.statusLabel)
                .font(theme.sans(15, .semibold))
                .foregroundStyle(theme.ink)
            if let detail {
                Text(detail)
                    .font(theme.sans(12))
                    .foregroundStyle(theme.ink2)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private extension ApertureOrbMode {
    init(phase: VoiceSessionPhase) {
        switch phase {
        case .idle: self = .resting
        case .listening, .speechDetected: self = .listening
        case .thinking: self = .thinking
        case .preparingSpeech: self = .preparing
        case .speaking: self = .speaking
        case .interrupted, .paused: self = .settling
        case .failed: self = .failed
        }
    }
}

private struct ApertureConfiguration: Equatable, Sendable {
    let mode: ApertureOrbMode
    let dark: Bool
    let reduceMotion: Bool
    let reducedQuality: Bool
    let fallbackLevel: Float
    let samplesLiveAudio: Bool
    let active: Bool
}

private struct ApertureMetalSurface: UIViewRepresentable {
    let configuration: ApertureConfiguration
    func makeUIView(context: Context) -> ApertureMTKView {
        ApertureMTKView(configuration: configuration)
    }
    func updateUIView(_ view: ApertureMTKView, context: Context) { view.apply(configuration) }
    static func dismantleUIView(_ view: ApertureMTKView, coordinator: ()) { view.stop() }
}

/// Metal resources shared by every orb instance. The settings preview and the
/// voice screen can be on screen at the same time, and each used to build its
/// own device, default library and pipeline on the main thread.
private final class ApertureMetalCache: @unchecked Sendable {
    static let shared = ApertureMetalCache()

    private let lock = NSLock()
    private var cachedDevice: MTLDevice?
    private var deviceResolved = false
    private var pipelines: [UInt: MTLRenderPipelineState] = [:]
    private var cachedDepthState: MTLDepthStencilState?

    var device: MTLDevice? {
        lock.lock(); defer { lock.unlock() }
        if !deviceResolved {
            cachedDevice = MTLCreateSystemDefaultDevice()
            deviceResolved = true
        }
        return cachedDevice
    }

    func pipeline(device: MTLDevice, pixelFormat: MTLPixelFormat,
                  sampleCount: Int) -> MTLRenderPipelineState? {
        let key = UInt(pixelFormat.rawValue) << 8 | UInt(sampleCount)
        lock.lock()
        let cached = pipelines[key]
        lock.unlock()
        if let cached { return cached }

        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "apertureOrbVertex"),
              let fragment = library.makeFunction(name: "apertureOrbFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Aperture ribbon sculpture"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = sampleCount
        descriptor.isAlphaToCoverageEnabled = sampleCount > 1
        guard let built = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        lock.lock()
        pipelines[key] = built
        lock.unlock()
        return built
    }

    func depthState(device: MTLDevice) -> MTLDepthStencilState? {
        lock.lock(); defer { lock.unlock() }
        if let cachedDepthState { return cachedDepthState }
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = true
        let state = device.makeDepthStencilState(descriptor: descriptor)
        cachedDepthState = state
        return state
    }
}

@MainActor
private final class ApertureMTKView: MTKView {
    private var orbRenderer: ApertureMetalRenderer?
    private var configuration: ApertureConfiguration
    private var budget: ApertureOrbBudget
    private var cancellables: Set<AnyCancellable> = []
    private var recoveryTask: Task<Void, Never>?
    private var fallbackLayers: [CAShapeLayer] = []

    init(configuration: ApertureConfiguration) {
        self.configuration = configuration
        budget = Self.budget(for: configuration)
        let metalDevice = ApertureMetalCache.shared.device
        super.init(frame: .zero, device: metalDevice)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // sRGB target: `shade` in the fragment shader is display-referred, so a
        // plain unorm target both darkened the sculpture and banded the smooth
        // shade ramp into visible contours that crawled as it rotated.
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float
        sampleCount = metalDevice?.supportsTextureSampleCount(4) == true ? 4 : 1
        framebufferOnly = true
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        if let metalDevice {
            orbRenderer = try? ApertureMetalRenderer(device: metalDevice,
                pixelFormat: colorPixelFormat, sampleCount: sampleCount,
                configuration: configuration, budget: budget)
        }
        delegate = orbRenderer
        if orbRenderer == nil { installFallback() }
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(tilt(_:))))
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshBudget() } }
                .store(in: &cancellables)
        }
        configureCadence()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func budget(for configuration: ApertureConfiguration) -> ApertureOrbBudget {
        ApertureOrbBudget(reduced: configuration.reducedQuality,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            reduceMotion: configuration.reduceMotion)
    }

    func apply(_ configuration: ApertureConfiguration) {
        // SwiftUI re-invokes this on every update of the host view. Re-running
        // the budget/cadence path each time reassigned `preferredFramesPerSecond`
        // and `isPaused`, which churns the display link's pacing.
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        orbRenderer?.update(configuration)
        refreshBudget()
    }

    private func refreshBudget() {
        let desired = Self.budget(for: configuration)
        // Downgrade immediately. A recovery must remain favorable for twelve
        // seconds so thermal changes cannot repeatedly alter geometry density.
        if desired.ribbons > budget.ribbons && !configuration.reduceMotion {
            if recoveryTask == nil {
                recoveryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled, let self else { return }
                    self.recoveryTask = nil
                    self.budget = Self.budget(for: self.configuration)
                    self.configureCadence()
                }
            }
        } else {
            recoveryTask?.cancel()
            recoveryTask = nil
            budget = desired
        }
        configureCadence()
    }

    private func configureCadence() {
        orbRenderer?.setBudget(budget)
        let framesPerSecond = min(max(1, budget.framesPerSecond),
                                  window?.screen.maximumFramesPerSecond ?? 60)
        if preferredFramesPerSecond != framesPerSecond { preferredFramesPerSecond = framesPerSecond }
        let paused = !configuration.active || window == nil
            || configuration.reduceMotion || orbRenderer == nil
        if isPaused != paused { isPaused = paused }
        updateDrawableSize()
        redrawStaticPose()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        orbRenderer?.resetFrameTime()
        configureCadence()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
        layoutFallback()
        redrawStaticPose()
    }

    private func updateDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let longest = max(bounds.width, bounds.height)
        let scale = min(window?.screen.scale ?? 2, CGFloat(budget.maximumDrawableDimension) / longest)
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if drawableSize != size { drawableSize = size }
    }

    private func redrawStaticPose() {
        guard configuration.active, window != nil else { return }
        if configuration.reduceMotion { draw() }
        if orbRenderer == nil { layoutFallback() }
    }

    /// The orb lives inside a vertically scrolling voice screen, so an ungated
    /// pan recognizer stole every scroll that started on it. Claim only clearly
    /// horizontal drags and let the scroll view win the rest. UIKit consults
    /// this on the gesture's view, so no delegate is needed.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let translation = pan.translation(in: self)
        return abs(translation.x) > 8 && abs(translation.x) > abs(translation.y) * 1.5
    }

    @objc private func tilt(_ gesture: UIPanGestureRecognizer) {
        guard !configuration.reduceMotion else { return }
        let translation = gesture.translation(in: self)
        let released = gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed
        orbRenderer?.setTilt(released ? .zero : SIMD2(
            Float(tanh(translation.x / 150)) * 0.5,
            Float(tanh(translation.y / 150)) * 0.5))
    }

    private func installFallback() {
        // Metal failure still leaves a legible native sculpture and state label.
        for _ in 0..<12 {
            let ribbon = CAShapeLayer()
            ribbon.fillColor = UIColor.clear.cgColor
            ribbon.lineWidth = 1.5
            layer.addSublayer(ribbon)
            fallbackLayers.append(ribbon)
        }
    }

    private func layoutFallback() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, ribbon) in fallbackLayers.enumerated() {
            let inset = CGFloat(index) * 0.012 + 0.15
            let rect = bounds.insetBy(dx: bounds.width * inset, dy: bounds.height * (0.22 + CGFloat(index) * 0.008))
            ribbon.path = UIBezierPath(ovalIn: rect).cgPath
            ribbon.strokeColor = (configuration.dark ? UIColor.lightGray : UIColor.darkGray).cgColor
            ribbon.transform = CATransform3DMakeRotation(CGFloat(index) * 0.035, 0, 0, 1)
        }
        CATransaction.commit()
    }

    func stop() {
        isPaused = true
        recoveryTask?.cancel()
        recoveryTask = nil
        cancellables.removeAll()
        delegate = nil
        orbRenderer = nil
    }
}

private struct ApertureUniforms {
    var shape = SIMD4<Float>(repeating: 0)
    // time, activity, horizontal touch tilt, vertical touch tilt
    var motion = SIMD4<Float>(repeating: 0)
    // aspect, dark appearance, segments, ribbons
    var presentation = SIMD4<Float>(repeating: 0)
}

private final class ApertureMetalRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState?
    private let lock = NSLock()
    // Three deep: with two, any GPU/CPU overlap contention made `draw(in:)`
    // bail without presenting, which the display turned into a pacing hitch.
    private let framesInFlight = DispatchSemaphore(value: 3)
    private var configuration: ApertureConfiguration
    private var budget: ApertureOrbBudget
    private var motion: ApertureOrbMotion
    private var lastFrameTime = CACurrentMediaTime()
    private var targetTilt = SIMD2<Float>.zero
    private var tilt = SIMD2<Float>.zero

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, sampleCount: Int,
         configuration: ApertureConfiguration, budget: ApertureOrbBudget) throws {
        guard let queue = device.makeCommandQueue(),
              let cachedPipeline = ApertureMetalCache.shared
                  .pipeline(device: device, pixelFormat: pixelFormat, sampleCount: sampleCount) else {
            throw ApertureError.unavailable
        }
        pipeline = cachedPipeline
        depthState = ApertureMetalCache.shared.depthState(device: device)
        commandQueue = queue
        self.configuration = configuration
        self.budget = budget
        motion = ApertureOrbMotion(mode: configuration.mode)
        super.init()
    }

    func update(_ configuration: ApertureConfiguration) {
        lock.lock(); defer { lock.unlock() }
        if !self.configuration.active && configuration.active { lastFrameTime = CACurrentMediaTime() }
        self.configuration = configuration
        motion.retarget(configuration.mode)
    }
    func setBudget(_ budget: ApertureOrbBudget) {
        lock.lock(); defer { lock.unlock() }
        guard self.budget != budget else { return }
        self.budget = budget
    }
    func setTilt(_ value: SIMD2<Float>) {
        lock.lock(); defer { lock.unlock() }
        targetTilt = value
    }
    func resetFrameTime() {
        lock.lock(); defer { lock.unlock() }
        lastFrameTime = CACurrentMediaTime()
    }

    func draw(in view: MTKView) {
        // Never wait behind inference work or accumulate stale visual frames.
        guard framesInFlight.wait(timeout: .now()) == .success else { return }
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            framesInFlight.signal()
            return
        }
        var uniforms = snapshot(
            aspect: Float(view.drawableSize.width / max(view.drawableSize.height, 1)),
            cadence: 1.0 / Double(max(view.preferredFramesPerSecond, 1))
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ApertureUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
            vertexCount: Int(uniforms.presentation.z * uniforms.presentation.w) * 6)
        encoder.endEncoding()
        let semaphore = framesInFlight
        buffer.addCompletedHandler { _ in semaphore.signal() }
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func snapshot(aspect: Float, cadence: TimeInterval) -> ApertureUniforms {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let measured = min(max(now - lastFrameTime, 0), 1.0 / 15)
        lastFrameTime = now
        // `dt` drives both the shape spring and the time integral, so jitter in
        // when the display-link callback reaches us turned straight into jitter
        // in the motion. Quantize to the requested cadence while the measured
        // interval is close; keep the real interval when a frame was genuinely
        // late so the animation never runs ahead of the clock.
        let elapsed = abs(measured - cadence) <= cadence * 0.35 ? cadence : measured
        let level: Float
        switch configuration.mode {
        case .listening: level = configuration.samplesLiveAudio
            ? max(configuration.fallbackLevel, VoiceVisualLevelStore.shared.micLevel) : configuration.fallbackLevel
        case .speaking: level = configuration.samplesLiveAudio
            ? max(configuration.fallbackLevel, VoiceVisualLevelStore.shared.playbackLevel) : configuration.fallbackLevel
        default: level = 0
        }
        motion.advance(elapsed: elapsed, level: level, reduceMotion: configuration.reduceMotion)
        tilt += (targetTilt - tilt) * Float(1 - exp(-elapsed * 12))
        if configuration.reduceMotion { tilt = .zero }
        return ApertureUniforms(shape: motion.shape,
            motion: SIMD4(Float(motion.time), motion.activity, tilt.x, tilt.y),
            presentation: SIMD4(aspect, configuration.dark ? 1 : 0, Float(budget.segments), Float(budget.ribbons)))
    }
}

private enum ApertureError: Error { case unavailable }
