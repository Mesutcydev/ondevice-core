# Release audit — 2026-10-09

The owner requested a fresh release audit, fixes that preserve functionality,
and a new TestFlight upload after validation. Bonsai 2 integration is deferred.
This candidate includes the prior opt-in TurboQuant update; the setting stays
off by default. Earlier working-tree changes are retained.

**Result: fresh beta uploaded, Apple processing `VALID`, internal TestFlight
state `IN_BETA_TESTING`. Public App Review remains subject to the conditions
below.**

Candidate: **OnDevice Max 1.0 (83)**, app `6818199563`, bundle
`com.mesutcydev.ondevicemax`, team `PUH4GMFV56`. A fresh authenticated lookup
confirmed build 82 was the latest upload and `VALID` before choosing 83.
The app and share extension use the same build number from `project.yml`.

## Findings and corrections

| Finding | Correction | Verification |
| --- | --- | --- |
| The archive command allowed package re-resolution during packaging | Require the reviewed `Package.resolved` versions and skip package updates | Fresh shipping archive passed; all 18 checkout revisions remain exact and clean |
| Lock-protected architecture/thinking metadata caches inherited main-actor isolation while their readers are nonisolated | Mark the immutable, Sendable lock declarations nonisolated; retain the same synchronized storage and lookup behavior | Actual Release app and tests compiled; these warnings are gone |
| The classifier metadata helper awaited an immutable nonisolated contract | Remove the unnecessary await; retain identical metadata | 33 classifier/store contracts pass; actual Release app compiles |
| Device-test signing used a stale UI-runner profile and Xcode had no account available to replace it | Use the existing owner API credential through Xcode's documented signing arguments; the archive/export script now supports an optional complete API signing configuration | Authenticated compile/signing completed; incomplete API configuration is rejected before archiving; device trust failure remains below |
| Previous GPU checks covered the Mac, without new iPhone evidence | Add small model-free iPhone kernel tests through the existing generation gate: affine 1/4/8-bit matmul, TurboQuant FP16/BF16 decode, trim/reset and rotating-cache preservation | Compiled; execution blocked by the device signature-trust failure below |

No inference loader, model weights, remote fallback, entitlement capability,
navigation design, or dependency upgrade is added by these release fixes.
Memory admission, model residency, cancellation, background cleanup and
thermal refusals retain their existing paths. Bonsai 2 remains unsupported.

## Validation and candidate identity

Evidence is retained under ignored `build/release-audit-2026-10-09/` and,
after packaging, `build/appstore/1.0-83/`. The initial source fingerprint
covers 1,081 files, including the pre-existing local changes. Shipping Xcode
27.0 (`27A266a`) and its CoreAI device SDK passed local preflight with the
existing shipping build cache. Apple's [release listing](https://developer.apple.com/news/releases/)
and [upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
were checked again on October 9. The beta Xcode installation is not selected
for distribution.

- App Store source verification and **24** distribution-policy unit tests pass.
- **134** memory-budget checks, **6** quantization-policy tests and **33**
  classifier/store tests pass with shipping Xcode.
- Public catalog invariants pass. All **35** catalog packs pass exact-revision
  download probes using 1,024-byte ranged requests; no model weights are downloaded.
- All **18** remote package checkouts match the reviewed lockfile revisions,
  with no tracked source edits in the checkouts.
- Earlier October 9 evidence for unchanged inputs remains applicable:
  **84** synthetic Mac GPU checks, **25** VoiceAgentOrb tests, and **2** native
  TurboQuant settings UI tests, plus the strengthened large-text rerun.
  The GPU checks use the same pinned PrismML/MLXLM revisions; the settings row,
  preference implementation and voice package sources have not changed in this
  release pass. Logs/results are in `build/quantization-updates-2026-10-09/`.
  These are retained results from earlier checks, not newly executed iPhone tests.
- Fresh **archive and App Store export pass** with shipping Xcode `27A266a`,
  owner-team signing, public `APP_STORE` policy and the reviewed dependency
  versions. The app and share extension both report **1.0 (83)** and
  `iphoneos27.0`. Strict distribution signatures, provisioning profiles,
  privacy manifests, entitlements, required licenses and resource checks pass.
  Production CloudKit and required memory/addressing capabilities are preserved;
  debugging memory, debugging access and PCC are absent from distribution claims.
- FoundationModels verification passes for **170** imported symbols, with
  no deprecated-renamed or missing imports. The IPA contains no `.xctest`
  bundles or FastVLM research artifacts. Repository validation and diff checks pass.
- All **895 authoritative input files** remained unchanged through archiving.
  CocoaPods/project regeneration changed only the generated `.pbxproj`; that
  generated project was captured and remained stable during compilation.
  Source fingerprints, both package-lock copies and all 18 checkout revisions
  were verified again before upload.
- The archive retains upstream generated Metal C++17-extension warnings and
  vendored CoreAI unused/mutability diagnostics. The corrected app cache
  isolation and redundant-await warnings are gone. The optional bundled Lens
  model is absent; its existing explicit download flow remains required.
- A paired physical iPhone 17 Pro Max, iOS 27.2, is reachable over the local
  network. Synthetic kernel tests establish device math and cache behavior;
  they do not measure real model quality, long-session thermals or content safety.
- The first physical-device attempt stopped before execution because the UI
  test runner's cached profile did not contain the current development certificate.
  Its failed result is retained; it is not recorded as a test pass.
- The authenticated attempt compiled and signed the actual Release app,
  extension and test targets with shipping Xcode and the public model policy.
  Compiled-bundle resource/metadata verification passes for **1.0 (83)**.
  The phone rejected installation with `0xe8008018`, so **no iPhone tests
  executed**. The selected development certificate's fingerprint matches
  Apple's active certificate record, expires October 1, 2027, and is authorized
  by the embedded profile, which includes this iPhone. An early suggestion
  that Xcode selected a revoked certificate was disproved by this comparison.
  The cause of the device trust rejection is not confirmed. No certificates
  were revoked and no device trust settings or user data were reset.
- Apple DTS recommends configuration/account review for similar valid-certificate
  installation failures ([Apple support discussion](https://developer.apple.com/forums/thread/798110)).
  The failed `.xcresult` and certificate/profile checks are retained locally;
  no support request or device diagnostics were sent to Apple.

## Remaining public-release conditions

The [October 8 compliance fixes](APP_STORE_COMPLIANCE_FIXES_2026-10-08.md)
remain the source for unresolved public-release conditions: Stability
commercial registration evidence, App Privacy publication/accuracy
attestation, reviewed website policy additions, and effective generated-content
safety/age-rating validation. Real model inference, downloads, camera/voice,
production CloudKit and sustained memory/thermal behavior need acceptance
on the signed candidate. A successful unit test or Apple processing result
does not close those conditions. No public App Review submission is requested.

## TestFlight result

The verified **1.0 (83)** IPA was accepted through Apple's App Store Connect
upload API. A direct build lookup confirms **`VALID`** and its pre-release
version confirms **1.0, iOS**. Its beta detail confirms **`IN_BETA_TESTING`**
internally; external state is `READY_FOR_BETA_SUBMISSION`. The existing internal
“Me” group has access to all builds. No tester invitations or public submission
were added. Build 82 is preserved.

Build ID: `9f85dcc8-ff3e-467f-9451-170d8b43a050`.
Apple's build upload timestamp: **October 9, 2026, 14:13:22 Europe/Istanbul**.
[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).
Final processing, beta status, pre-release version and the upload summary are
saved under `build/appstore/1.0-83/`.

IPA: `build/appstore/1.0-83/export/OnDeviceMax.ipa` (approximately 80 MiB).
SHA-256: `f5ce04af9ae4081c67a1b483203a09a8d473f1f52dfc34654299d79e9f685ad4`.
The local hash was checked before upload and the CLI checksum option enabled;
Apple's API supplied no server checksums, as recorded in the upload log.
No public App Review submission or tester invitation is performed.
