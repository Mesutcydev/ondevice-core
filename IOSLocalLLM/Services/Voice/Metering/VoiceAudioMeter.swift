import AVFoundation
import Foundation

// MARK: - VoiceAudioMetering
// Smooths raw amplitude into a UI-safe 0…1 level at ~30 FPS.

protocol VoiceAudioMetering: Sendable {
    var levelStream: AsyncStream<Float> { get }
}

/// Attack/release smoother with a soft-knee noise floor.
///
/// The time constants are in **seconds**, so the envelope no longer depends on
/// the tick rate the caller happens to get — the meter link is a display link
/// the system may thin under load, and per-tick coefficients made the orb's
/// response speed up and slow down with it.
/// Not Sendable in practice for mutation — call only from one actor.
final class VoiceLevelSmoother: @unchecked Sendable {
    private var previous: Float = 0
    private let attack: Float
    private let release: Float
    private let noiseFloor: Float
    private let peakClamp: Float

    /// - Parameters:
    ///   - attack: rise time constant, seconds.
    ///   - release: fall time constant, seconds.
    ///   - noiseFloor: level below which input is attenuated to silence.
    init(
        attack: Float = 0.06,
        release: Float = 0.26,
        noiseFloor: Float = 0.04,
        peakClamp: Float = 1.0
    ) {
        self.attack = attack
        self.release = release
        self.noiseFloor = noiseFloor
        self.peakClamp = peakClamp
    }

    /// `newLevel` should already be roughly 0…1 (peak or RMS normalized).
    /// `dt` is the wall time since the previous call, in seconds.
    func smooth(_ newLevel: Float, dt: Float = 1.0 / 30.0) -> Float {
        let gated = Self.gate(min(peakClamp, max(0, newLevel)), noiseFloor: noiseFloor)
        let tau = gated > previous ? attack : release
        let elapsed = max(dt.isFinite ? dt : 0, 0)
        previous += (gated - previous) * (1 - exp(-elapsed / max(tau, 1e-4)))
        return previous
    }

    /// Soft knee around the noise floor: continuous in both value and slope, so
    /// a quiet tail settling through the floor fades out instead of ticking to
    /// zero. The hard `x < floor ? 0 : x` gate this replaces was one of three
    /// stacked thresholds that made the orb flutter near silence.
    static func gate(_ value: Float, noiseFloor: Float) -> Float {
        guard value.isFinite else { return 0 }
        let clamped = max(value, 0)
        let floor = max(noiseFloor, 0)
        guard floor > 0 else { return min(clamped, 1) }
        let knee = floor * 2
        let shaped = clamped <= knee
            ? (clamped * clamped) / (2 * knee)
            : clamped - knee / 2
        return min(shaped / max(1 - knee / 2, 1e-4), 1)
    }

    func reset() {
        previous = 0
    }
}

enum PCMAmplitudeAnalyzer {
    /// Peak absolute amplitude of a float PCM buffer, normalized 0…1.
    static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0,
              let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        var peak: Float = 0
        // Stride through samples to keep this cheap for long chunks.
        let step = max(1, count / 2048)
        var i = 0
        while i < count {
            let v = abs(data[i])
            if v > peak { peak = v }
            i += step
        }
        // Soft knee so quiet TTS still moves the orb a bit.
        return min(1, peak * 1.8)
    }

    /// Coarse envelope samples across the buffer for playback-time lookup.
    static func envelope(of buffer: AVAudioPCMBuffer, bins: Int = 48) -> [Float] {
        guard buffer.frameLength > 0,
              let data = buffer.floatChannelData?[0],
              bins > 0 else { return [] }
        let count = Int(buffer.frameLength)
        let binSize = max(1, count / bins)
        var result: [Float] = []
        result.reserveCapacity(bins)
        var offset = 0
        for _ in 0..<bins {
            let end = min(offset + binSize, count)
            var peak: Float = 0
            var i = offset
            while i < end {
                let v = abs(data[i])
                if v > peak { peak = v }
                i += 1
            }
            result.append(min(1, peak * 1.8))
            offset = end
            if offset >= count { break }
        }
        return result
    }

    static func level(at progress: Double, envelope: [Float]) -> Float {
        guard !envelope.isEmpty else { return 0 }
        let p = min(1, max(0, progress))
        let idx = Int(p * Double(envelope.count - 1))
        return envelope[min(max(idx, 0), envelope.count - 1)]
    }
}

/// Throttles meter ticks to ~24 FPS on the main RunLoop.
final class VoiceMeterDisplayLink: @unchecked Sendable {
    private var timer: Timer?
    private let interval: TimeInterval
    private var handler: (() -> Void)?

    init(fps: Double = 24) {
        self.interval = 1.0 / max(fps, 1)
    }

    @MainActor
    func start(_ handler: @escaping () -> Void) {
        stop()
        self.handler = handler
        // Main RunLoop timer — invoke directly (no Task { @MainActor } hop).
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.handler?()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        #if DEBUG
        VoiceDiagnosticsCenter.shared.noteDisplayLink(active: true)
        #endif
    }

    @MainActor
    func stop() {
        let wasRunning = timer != nil
        timer?.invalidate()
        timer = nil
        handler = nil
        #if DEBUG
        if wasRunning {
            VoiceDiagnosticsCenter.shared.noteDisplayLink(active: false)
        }
        #endif
    }

    deinit {
        timer?.invalidate()
    }
}
