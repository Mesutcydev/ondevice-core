import XCTest
@testable import IOSLocalLLM

// MARK: - Private Cloud Compute entitlement gate
//
// `PrivateCloudComputeLanguageModel` traps with a fatalError when the running
// binary lacks `com.apple.developer.private-cloud-compute`, while
// `availability` still reports the model as usable. A sideloaded, re-signed
// IPA normally has no such entitlement, so the app must never touch the model
// — not even to read its availability — unless this process actually carries
// the entitlement.
//
// These tests run on any host. On an unentitled host (every simulator run) they
// prove the refusal path; on an entitled install that path is legitimately
// unreachable, so those cases skip rather than assert a state that cannot exist
// there.

final class PCCEntitlementTests: XCTestCase {

    /// The refusal path is only observable in a process without the
    /// entitlement. Skipping keeps the suite honest on an entitled device.
    private func requireUnprovisionedHost() throws {
        try XCTSkipIf(
            EntitlementsProbe.isPrivateCloudUsable,
            "Host is PCC-entitled — the refusal path is not observable here."
        )
    }

    // MARK: entitlement probe

    func test_entitlementProbeIsAlwaysConclusive() {
        // Never throws, never traps; an unreadable signature means "not
        // provisioned", which is the safe answer.
        XCTAssertFalse(EntitlementsProbe.detectionSummary.isEmpty)
        XCTAssertEqual(
            EntitlementsProbe.signatureHasPrivateCloud,
            EntitlementsProbe.current[EntitlementsProbe.privateCloudKey] as? Bool == true
        )
    }

    // MARK: the decision rule (pure — every combination)

    func test_gate_requiresTheSignatureKey() {
        XCTAssertFalse(EntitlementsProbe.isGranted(
            signatureEntitled: false, hasEmbeddedProfile: false, profileEntitled: false))
        XCTAssertFalse(EntitlementsProbe.isGranted(
            signatureEntitled: false, hasEmbeddedProfile: true, profileEntitled: true),
            "a profile alone cannot grant what the signature does not carry")
    }

    func test_gate_signatureOnlyInstallIsAccepted() {
        XCTAssertTrue(EntitlementsProbe.isGranted(
            signatureEntitled: true, hasEmbeddedProfile: false, profileEntitled: false))
    }

    func test_gate_profileMustGrantWhenOneIsEmbedded() {
        // The re-sign case: the blob survives but the installer's profile does
        // not grant the capability, so the system would refuse it at runtime.
        XCTAssertFalse(EntitlementsProbe.isGranted(
            signatureEntitled: true, hasEmbeddedProfile: true, profileEntitled: false))
        XCTAssertTrue(EntitlementsProbe.isGranted(
            signatureEntitled: true, hasEmbeddedProfile: true, profileEntitled: true))
    }

    func test_profileParserRejectsANonProfileBlob() {
        XCTAssertNil(EntitlementsProbe.provisioningProfilePlist(in: Data("not a profile".utf8)))
    }

    func test_profileParserReadsEntitlementsOutOfAWrappedBlob() throws {
        // A provisioning profile is a CMS blob around this plist; the slice must
        // survive arbitrary binary outside the XML delimiters.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Name</key><string>Test Profile</string>
          <key>Entitlements</key><dict>
            <key>\(EntitlementsProbe.privateCloudKey)</key><true/>
          </dict>
        </dict></plist>
        """
        var blob = Data([0x30, 0x82, 0x01, 0x00, 0xde, 0xad, 0xbe, 0xef])
        blob.append(Data(plist.utf8))
        blob.append(Data([0x00, 0x01, 0x02, 0x03]))

        let parsed = try XCTUnwrap(EntitlementsProbe.provisioningProfilePlist(in: blob))
        XCTAssertEqual(parsed["Name"] as? String, "Test Profile")
        let entitlements = try XCTUnwrap(parsed["Entitlements"] as? [String: Any])
        XCTAssertEqual(entitlements[EntitlementsProbe.privateCloudKey] as? Bool, true)
    }

    func test_applePrivateCloudGateUsesTheProbe() {
        XCTAssertEqual(
            ApplePrivateCloud.isProvisionedForCurrentBuild,
            EntitlementsProbe.isPrivateCloudUsable
        )
    }

    // MARK: facade must not touch the framework

    func test_statusFollowsTheEntitlementGate() async {
        let status = await ApplePrivateCloud.currentStatus()
        if ApplePrivateCloud.isProvisionedForCurrentBuild {
            XCTAssertNotEqual(status, .entitlementUnavailable)
        } else {
            XCTAssertEqual(status, .entitlementUnavailable)
            XCTAssertFalse(status.canSend)
        }
    }

    func test_contextSizeOnUnprovisionedBuildIsNil() async throws {
        try requireUnprovisionedHost()
        let size = await ApplePrivateCloud.contextSize()
        XCTAssertNil(size)
    }

    func test_streamOnUnprovisionedBuildFailsCleanly() async throws {
        try requireUnprovisionedHost()
        var thrown: Error?
        do {
            for try await _ in await ApplePrivateCloud.stream(
                ApplePCCRequest(prompt: "hello")
            ) {}
        } catch {
            thrown = error
        }
        XCTAssertEqual(thrown as? ApplePCCError, .notProvisioned)
    }

    func test_answerOnUnprovisionedBuildThrowsCleanly() async throws {
        try requireUnprovisionedHost()
        do {
            _ = try await ApplePrivateCloud.answer(ApplePCCRequest(prompt: "hello"))
            XCTFail("answer must not succeed on an unprovisioned build")
        } catch {
            XCTAssertEqual(error as? ApplePCCError, .notProvisioned)
        }
    }

    // MARK: UI-facing mapping

    func test_entitlementStatusOutranksOsGate() {
        // The status carries its own user-facing copy and is never sendable.
        XCTAssertFalse(ApplePCCStatus.entitlementUnavailable.canSend)
        XCTAssertTrue(ApplePCCError.notProvisioned.errorDescription?
            .contains("entitlement") == true)
    }

    func test_unavailableErrorNamesTheMostSpecificGate() {
        let error = ApplePrivateCloud.unavailableError
        if !ApplePrivateCloud.isCompiledIn {
            XCTAssertEqual(error, .notCompiledIn)
        } else if !ApplePrivateCloud.isSupportedOnCurrentOS {
            XCTAssertEqual(error, .unsupportedOS)
        } else if !ApplePrivateCloud.isProvisionedForCurrentBuild {
            XCTAssertEqual(error, .notProvisioned)
        }
    }

    // MARK: service-level dispatch

    @MainActor
    func test_serviceRefreshReportsEntitlementInsteadOfUnsupportedOS() async throws {
        try requireUnprovisionedHost()
        let assistant = CodingAssistantService.shared
        await assistant.refreshApplePrivateCloudStatus()
        XCTAssertEqual(assistant.applePrivateCloudStatus, .entitlementUnavailable)
        XCTAssertNil(assistant.applePrivateCloudContextSize)
    }

    @MainActor
    func test_selectingPCCOnUnprovisionedBuildIsRefused() async throws {
        try requireUnprovisionedHost()
        let assistant = CodingAssistantService.shared
        let selected = await assistant.selectApplePrivateCloud(persistAsDefault: false)
        XCTAssertFalse(selected)
        XCTAssertNotEqual(assistant.activeSelectionID, ApplePrivateCloud.modelID)
    }

    @MainActor
    func test_unprovisionedBuildRepairsAStalePersistedPCCDefault() async throws {
        try requireUnprovisionedHost()
        let settings = AppSettings.shared
        let original = settings.assistantModelID
        defer { settings.assistantModelID = original }

        settings.assistantModelID = ApplePrivateCloud.modelID
        _ = await CodingAssistantService.shared.selectApplePrivateCloud(persistAsDefault: false)

        XCTAssertNotEqual(
            settings.assistantModelID,
            ApplePrivateCloud.modelID,
            "an unrunnable persisted default must be repaired, not kept"
        )
    }
}