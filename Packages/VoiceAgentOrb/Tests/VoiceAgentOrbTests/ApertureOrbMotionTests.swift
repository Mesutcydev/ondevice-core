import Foundation
import Testing
@testable import VoiceAgentOrb

@Suite("Aperture orb continuity and rendering budget")
struct ApertureOrbMotionTests {
    @Test("Interrupted transitions retain the visible shape and velocity")
    func interruptedTransition() {
        var motion = ApertureOrbMotion()
        motion.retarget(.thinking)
        for _ in 0..<5 { motion.advance(elapsed: 1.0 / 60, level: 0, reduceMotion: false) }
        let shape = motion.shape
        let velocity = motion.velocity
        motion.retarget(.preparing)
        motion.retarget(.speaking)
        #expect(motion.shape == shape)
        #expect(motion.velocity == velocity)
        motion.advance(elapsed: 0.000001, level: 0.5, reduceMotion: false)
        for i in 0..<4 { #expect(abs(motion.shape[i] - shape[i]) < 0.0001) }
    }

    @Test("30 and 60 Hz converge to the same shape")
    func frameIndependence() {
        var slow = ApertureOrbMotion()
        var fast = slow
        slow.retarget(.thinking)
        fast.retarget(.thinking)
        for _ in 0..<30 { slow.advance(elapsed: 1.0 / 30, level: 0, reduceMotion: false) }
        for _ in 0..<60 { fast.advance(elapsed: 1.0 / 60, level: 0, reduceMotion: false) }
        for i in 0..<4 { #expect(abs(slow.shape[i] - fast.shape[i]) < 0.00001) }
    }

    @Test("Reduce Motion is static and ignores audio")
    func reducedMotion() {
        var motion = ApertureOrbMotion(mode: .speaking)
        motion.advance(elapsed: 1, level: 1, reduceMotion: true)
        let pose = motion.shape
        motion.advance(elapsed: 10, level: 0.8, reduceMotion: true)
        #expect(motion.shape == pose)
        #expect(motion.time == 0)
        #expect(motion.activity == 0)
        #expect(motion.velocity == .zero)
    }

    @Test("Audio and pause recovery stay finite and bounded")
    func boundedInput() {
        var motion = ApertureOrbMotion(mode: .listening)
        for level: Float in [.nan, .infinity, -10, 10, 0.01] {
            motion.advance(elapsed: 100, level: level, reduceMotion: false)
            #expect(motion.activity.isFinite && motion.activity >= 0 && motion.activity <= 1)
        }
        #expect(motion.time < 1)
        motion.retarget(.resting)
        for _ in 0..<240 { motion.advance(elapsed: 1.0 / 60, level: 1, reduceMotion: false) }
        #expect(motion.activity < 0.001)
    }

    @Test("Older devices and pressure use intact lower-cost geometry")
    func budgets() {
        func budget(reduced: Bool = false, lowPower: Bool = false,
                    thermal: ProcessInfo.ThermalState = .nominal,
                    memory: UInt64 = 8_589_934_592, motion: Bool = false) -> ApertureOrbBudget {
            ApertureOrbBudget(reduced: reduced, lowPower: lowPower, thermalState: thermal,
                              physicalMemory: memory, reduceMotion: motion)
        }
        let full = budget()
        #expect(full.framesPerSecond == 60)
        for reduced in [budget(reduced: true), budget(lowPower: true),
                         budget(thermal: .fair), budget(thermal: .critical), budget(memory: 4_294_967_296)] {
            #expect(reduced.framesPerSecond == 30)
            #expect(reduced.ribbons >= 20)
            #expect(reduced.segments >= 96)
            #expect(reduced.maximumDrawableDimension < full.maximumDrawableDimension)
        }
        #expect(budget(motion: true).framesPerSecond == 0)
    }

    @Test("Quiet audio still moves the sculpture — no consumer-side dead zone")
    func noDeadZone() {
        var quiet = ApertureOrbMotion(mode: .listening)
        var loud = ApertureOrbMotion(mode: .listening)
        for _ in 0..<120 {
            quiet.advance(elapsed: 1.0 / 60, level: 0.01, reduceMotion: false)
            loud.advance(elapsed: 1.0 / 60, level: 0.9, reduceMotion: false)
        }
        // The noise floor belongs to whoever measured the audio. A second
        // threshold here made the orb tick in and out near silence.
        #expect(abs(quiet.activity - 0.01) < 0.002)
        #expect(loud.activity > quiet.activity * 10)
    }

    @Test("Motion time wraps inside the shader period so Float keeps precision")
    func timeWraps() {
        var motion = ApertureOrbMotion(mode: .thinking)
        // ~35 minutes of the fastest pose at 60 Hz.
        for _ in 0..<126_000 { motion.advance(elapsed: 1.0 / 60, level: 0, reduceMotion: false) }
        #expect(motion.time >= 0)
        #expect(motion.time < 10 * .pi)
        // Wrapping must not disturb the pose spring.
        for i in 0..<4 { #expect(motion.shape[i].isFinite) }
    }
}
