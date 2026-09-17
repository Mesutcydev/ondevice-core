import Foundation

/// Semantic poses for the app's continuous, ribbon-built voice sculpture.
/// Every pose shares one topology; changing state never replaces particles.
public enum ApertureOrbMode: Sendable, CaseIterable {
    case resting, listening, thinking, preparing, speaking, settling, failed

    fileprivate var shape: SIMD4<Float> {
        // Major radius, tube radius, fold, tilt.
        switch self {
        case .resting:  return SIMD4(0.43, 0.19, 0.32, 0.48)
        case .listening:return SIMD4(0.47, 0.16, 0.46, 0.22)
        case .thinking: return SIMD4(0.38, 0.25, 1.35, 0.72)
        case .preparing:return SIMD4(0.34, 0.27, 0.72, 0.40)
        case .speaking: return SIMD4(0.43, 0.21, 0.68, 0.32)
        case .settling: return SIMD4(0.44, 0.17, 0.18, 0.58)
        case .failed:   return SIMD4(0.43, 0.16, 0.00, 0.18)
        }
    }

    fileprivate var pace: Float {
        switch self {
        case .resting: 0.16
        case .listening: 0.24
        case .thinking: 0.52
        case .preparing: 0.30
        case .speaking: 0.38
        case .settling: 0.10
        case .failed: 0
        }
    }
}

/// Pure, frame-rate independent motion. Retargeting preserves both position
/// and velocity, including several state changes within a single frame.
public struct ApertureOrbMotion: Sendable {
    public private(set) var shape: SIMD4<Float>
    public private(set) var velocity = SIMD4<Float>(repeating: 0)
    public private(set) var activity: Float = 0
    public private(set) var time: Double = 0
    public private(set) var mode: ApertureOrbMode
    private var pace: Float

    public init(mode: ApertureOrbMode = .resting) {
        self.mode = mode
        shape = mode.shape
        pace = mode.pace
    }

    public mutating func retarget(_ mode: ApertureOrbMode) {
        self.mode = mode
    }

    public mutating func advance(elapsed: Double, level: Float, reduceMotion: Bool) {
        if reduceMotion {
            // Stop immediately and take the pose for the current mode, but keep
            // the phase: also zeroing `time` made a runtime Reduce Motion toggle
            // jump the sculpture into its phase-zero pose on top of the shape
            // change.
            shape = mode.shape
            velocity = .zero
            activity = 0
            pace = mode.pace
            return
        }
        let dt = Float(elapsed.isFinite ? min(max(elapsed, 0), 1.0 / 15.0) : 0)
        guard dt > 0 else { return }
        // Exact solution of a critically damped spring, with no integration
        // overshoot when switching between 30 and 60 Hz.
        let omega: Float = 10
        let displacement = shape - mode.shape
        let carry = velocity + displacement * omega
        let decay = exp(-omega * dt)
        shape = mode.shape + (displacement + carry * dt) * decay
        velocity = (velocity - carry * omega * dt) * decay
        pace += (mode.pace - pace) * (1 - exp(-dt * 4))
        // The shader is periodic in `time` with period 10π (its terms run at
        // 1×, 4× and 0.6×), so wrapping there is seamless and keeps the Float
        // uniform from losing precision over a long session.
        time = (time + Double(pace * dt)).truncatingRemainder(dividingBy: 10 * .pi)

        let acceptsAudio = mode == .listening || mode == .speaking
        let bounded = level.isFinite && acceptsAudio ? min(max(level, 0), 1) : 0
        // No dead zone here: the noise floor belongs to whichever producer
        // measured the audio, and a second threshold on the consumer side made
        // the sculpture tick in and out whenever a quiet tail hovered at it.
        // Responsive attack, softer release: pauses between syllables do not
        // collapse the sculpture or amplify room-noise flutter.
        let response: Float = bounded > activity ? 0.10 : 0.32
        activity += (bounded - activity) * (1 - exp(-dt / response))
    }
}

/// A bounded native renderer budget. Device pressure always wins over the
/// visual preference. Lower tiers keep complete ribbons, not sparse points.
public struct ApertureOrbBudget: Sendable, Equatable {
    public let framesPerSecond: Int
    public let segments: Int
    public let ribbons: Int
    public let maximumDrawableDimension: Int

    public init(reduced: Bool, lowPower: Bool, thermalState: ProcessInfo.ThermalState,
                physicalMemory: UInt64, reduceMotion: Bool) {
        let constrained = reduced || lowPower || thermalState != .nominal
            || physicalMemory <= 4 * 1_024 * 1_024 * 1_024
        framesPerSecond = reduceMotion ? 0 : (constrained ? 30 : 60)
        segments = constrained ? 96 : 144
        ribbons = constrained ? 20 : 28
        // The orb is at most 280 pt across, so the old 840 cap was exactly 3×
        // and never actually capped anything. Ribbon shading is smooth and the
        // edge feather is analytic in screen space, so ~2.6× is indistinguishable
        // while cutting MSAA fill (and the depth buffer) by roughly a quarter.
        maximumDrawableDimension = constrained ? 560 : 720
    }
}
