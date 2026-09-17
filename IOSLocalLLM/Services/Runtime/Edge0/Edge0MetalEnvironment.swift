import Foundation
import Metal

// MARK: - Edge0MetalEnvironment
//
// Read-only mirror of MLX's NAX (Metal 4 neural-accelerator) gate. It
// changes no runtime behavior; it exists so Diagnostics can report which
// kernel regime this device and OS are inside, without touching the pinned
// MLX dependency.
//
// MLX's gate, from the pinned checkout
// (`Source/Cmlx/mlx/mlx/backend/metal/device.h:268`):
//
//   can_use_nax  = __builtin_available(macOS/iOS/tvOS/visionOS 26.2, *)
//   arch_        = MLX_METAL_GPU_ARCH, else device->architecture()->name()
//                  (e.g. "applegpu_g18p")
//   gen          = digits at [size-3][size-2] clamped to 0..9
//   can_use_nax &= gen >= (arch.back() == 'p' ? 18 : 17)   // 'p' = phone
//
// The authoritative answer is the kernel actually dispatched, not this
// mirror: confirm with a Metal System Trace on the device and look for
// `*_nax*` kernel names (see `Docs/EDGE0_PERF_UPDATE_SCAN_2026-09-17.md`).

struct Edge0MetalEnvironment: Sendable, Equatable {
    let deviceName: String
    /// Metal architecture name from the same source MLX reads,
    /// e.g. `applegpu_g18p`.
    let architecture: String
    let architectureGeneration: Int
    /// Trailing architecture class character: `p` phone, `g` base/pro,
    /// `s` max, `d` ultra.
    let architectureClass: Character
    let osSatisfiesAvailability: Bool
    /// Mirror of MLX's `is_nax_available()` for this device and OS.
    let naxEligible: Bool

    var summary: String {
        "metal \(architecture) · gen \(architectureGeneration)"
            + " · NAX \(naxEligible ? "eligible (verify in trace)" : "not eligible")"
    }

    /// Mirrors MLX's `arch_[size-3] / arch_[size-2]` digit parse with the
    /// same clamp-to-zero behavior for non-digits.
    static func parse(
        architecture: String
    ) -> (generation: Int, class: Character) {
        let characters = Array(architecture)
        var tens = 0
        var ones = 0
        if characters.count >= 3 {
            if let value = characters[characters.count - 3].wholeNumberValue,
               value < 10 {
                tens = value
            }
            if let value = characters[characters.count - 2].wholeNumberValue,
               value < 10 {
                ones = value
            }
        }
        return (tens * 10 + ones, characters.last ?? " ")
    }

    static func isNaxEligible(
        architecture: String,
        osSatisfiesAvailability: Bool
    ) -> Bool {
        guard osSatisfiesAvailability else { return false }
        let parsed = parse(architecture: architecture)
        let threshold = parsed.class == "p" ? 18 : 17
        return parsed.generation >= threshold
    }

    static func current() -> Edge0MetalEnvironment {
        let device = MTLCreateSystemDefaultDevice()
        let architecture: String
        if let override = ProcessInfo.processInfo
            .environment["MLX_METAL_GPU_ARCH"], !override.isEmpty {
            architecture = override
        } else {
            architecture = device?.architecture.name ?? ""
        }

        // Same runtime decision as MLX's `__builtin_available(iOS 26.2, ...)`,
        // expressed as an OS-version comparison so it stays valid regardless
        // of this target's deployment target.
        let available = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        )

        let parsed = parse(architecture: architecture)
        return Edge0MetalEnvironment(
            deviceName: device?.name ?? "unknown",
            architecture: architecture,
            architectureGeneration: parsed.generation,
            architectureClass: parsed.class,
            osSatisfiesAvailability: available,
            naxEligible: isNaxEligible(
                architecture: architecture,
                osSatisfiesAvailability: available
            )
        )
    }
}
