import Foundation

// MARK: - EntitlementsProbe
//
// Best-effort read of the entitlements baked into this process's own code
// signature.
//
// WHY THIS EXISTS: `PrivateCloudComputeLanguageModel` **traps with a fatalError**
// when the running binary lacks `com.apple.developer.private-cloud-compute`,
// while `availability` still reports the model as usable:
//
//     FoundationModels/PrivateCloudComputeLanguageModel.swift:963:
//     Fatal error: Process is missing required entitlement:
//     com.apple.developer.private-cloud-compute
//
// Reproduced on the iOS 27 simulator with the app's own facade: availability
// reported `.available`, `contextSize` returned 32768, and the trap fired on the
// first generation attempt. A sideloaded, re-signed IPA normally carries no such
// entitlement (it is provisioning-managed — only a profile that grants it may
// install it), so the app must know before it touches PCC at all.
//
// A trap cannot be caught in Swift, so this probe is the only defence: it runs
// before the model is constructed, before `availability` is read, and before a
// session is created.
//
// The Security framework's `SecTaskCopyValueForEntitlement` is macOS-only, so the
// entitlements blob (`CS_ENTITLEMENTS`, magic `0xfade7171`) is read directly out
// of our own executable. Read-only, no private API, never throws: any failure
// yields an empty dictionary, i.e. "not provisioned" — the safe answer.

// Keys granted by the embedded provisioning profile. The signature alone is
// not the whole contract: a re-signer can keep an app's entitlement blob while
// signing with a profile that does not grant it, and the system then refuses
// the capability at runtime — Apple's framework traps with the very same
// "missing required entitlement" message. Requiring BOTH is what makes the gate
// correct on every install path.

enum EntitlementsProbe {

    static let privateCloudKey = "com.apple.developer.private-cloud-compute"

    /// Entitlements found in the current executable (empty when unreadable).
    static var current: [String: Any] { loaded }

    /// True when this process's signature carries the PCC entitlement.
    static var signatureHasPrivateCloud: Bool {
        (loaded[privateCloudKey] as? Bool) == true
    }

    /// True when the embedded provisioning profile (if any) grants it.
    static var profileGrantsPrivateCloud: Bool {
        (profile[privateCloudKey] as? Bool) == true
    }

    /// The effective answer: may this process use Private Cloud Compute?
    static var isPrivateCloudUsable: Bool {
        isGranted(
            signatureEntitled: signatureHasPrivateCloud,
            hasEmbeddedProfile: hasEmbeddedProfile,
            profileEntitled: profileGrantsPrivateCloud
        )
    }

    /// The decision rule, pure so every combination is testable without a
    /// signed build.
    ///
    /// - signature without the key → never usable;
    /// - signature with the key and **no** embedded profile → the signature is
    ///   the whole contract (ad-hoc / sideload installs that carry no profile);
    /// - signature with the key **and** a profile → the profile must grant it,
    ///   otherwise the system will not honour the capability.
    static func isGranted(
        signatureEntitled: Bool,
        hasEmbeddedProfile: Bool,
        profileEntitled: Bool
    ) -> Bool {
        guard signatureEntitled else { return false }
        guard hasEmbeddedProfile else { return true }
        return profileEntitled
    }

    /// True when the bundle ships a provisioning profile.
    static var hasEmbeddedProfile: Bool { embeddedProfileData != nil }

    /// Entitlements granted by the embedded provisioning profile (empty when
    /// there is no profile, or when it cannot be read).
    static var profile: [String: Any] { loadedProfile }

    /// Diagnostic line for Settings → Diagnostics: what the probe saw.
    static var detectionSummary: String {
        if loaded.isEmpty { return "could not read this build's entitlements" }
        if !signatureHasPrivateCloud {
            return "no Private Cloud Compute entitlement in this build"
        }
        if !hasEmbeddedProfile {
            return "Private Cloud Compute entitlement present (entitlements only)"
        }
        return profileGrantsPrivateCloud
            ? "Private Cloud Compute entitlement present (profile grants it)"
            : "provisioning profile does not grant Private Cloud Compute"
    }

    // MARK: reading

    private static let loaded: [String: Any] = read()

    private static let embeddedProfileData: Data? = {
        guard let url = Bundle.main.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }()

    private static let loadedProfile: [String: Any] = {
        guard let data = embeddedProfileData,
              let plist = provisioningProfilePlist(in: data),
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return [:]
        }
        return entitlements
    }()

    /// A provisioning profile is a CMS blob wrapping an XML plist. There is no
    /// public API to decode it without invoking the whole CMS stack, so the
    /// plist is sliced out by its own delimiters; anything that does not parse
    /// yields `nil`, which callers read as "does not grant".
    static func provisioningProfilePlist(in data: Data) -> [String: Any]? {
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(
                of: Data("</plist>".utf8),
                options: [],
                in: xmlStart.lowerBound..<data.endIndex
              ) else { return nil }
        let slice = data[xmlStart.lowerBound..<xmlEnd.upperBound]
        return try? PropertyListSerialization.propertyList(
            from: slice,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private static func read() -> [String: Any] {
        guard let executable = Bundle.main.executableURL,
              let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else {
            return [:]
        }
        let bytes = [UInt8](data)

        // Code-signing blobs are big-endian; some producers have been seen
        // writing the reversed order, so both are tried. The first blob that
        // parses as a plist dictionary wins.
        for magic: [UInt8] in [[0xfa, 0xde, 0x71, 0x71], [0x71, 0x71, 0xde, 0xfa]] {
            var index = 0
            while index + 8 <= bytes.count {
                guard bytes[index] == magic[0],
                      bytes[index + 1] == magic[1],
                      bytes[index + 2] == magic[2],
                      bytes[index + 3] == magic[3] else {
                    index += 1
                    continue
                }

                let bigEndian = UInt32(bytes[index + 4]) << 24
                    | UInt32(bytes[index + 5]) << 16
                    | UInt32(bytes[index + 6]) << 8
                    | UInt32(bytes[index + 7])
                let length = Int(bigEndian)

                // Blob length includes the 8-byte header; sanity-bound it before
                // slicing.
                if length > 8, length <= 1 << 20, index + length <= bytes.count {
                    let payload = Data(bytes[(index + 8)..<(index + length)])
                    if let plist = try? PropertyListSerialization.propertyList(
                        from: payload, options: [], format: nil
                    ) as? [String: Any], !plist.isEmpty {
                        return plist
                    }
                }
                index += 4
            }
        }
        return [:]
    }
}