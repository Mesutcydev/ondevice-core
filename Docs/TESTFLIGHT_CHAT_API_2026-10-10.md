# TestFlight chat and API update — 2026-10-10

The owner requested the updated app on TestFlight as **1.0.1 (1)**. Apple
confirms processing **VALID** and internal TestFlight **IN_BETA_TESTING** for
build `78900c7b-07af-4fd5-8054-b727e4deec4b`, app `6818199563`, bundle
`com.mesutcydev.ondevicemax`, owner team `PUH4GMFV56`. Upload time was
**October 10, 2026, 15:37:10 Europe/Istanbul**. The existing internal **Me**
group has access to all builds; English test notes were published and verified.
External state is `READY_FOR_BETA_SUBMISSION`.

This build includes tool-result pills, context-compaction notices, timed
reasoning animation, and the red Stop button, retaining the existing chat
scrolling and streaming caret. API mode keeps provider/model selection in the
composer; local mode restores model selection to the centered top bar. Provider
configuration and model selection share the app's existing Settings cards,
semantic fonts, appearance, and native controls. See [API providers](API_PROVIDERS.md)
for the 13 public API presets, custom endpoints, credential handling, and consent.

The app and share extension both report **1.0.1 (1)**. Fresh archive and signed
App Store export passed with shipping Xcode **27A266a**, the public model
policy, owner-team profiles, Production CloudKit, and the required runtime
entitlements. Distribution signatures, bundled resources, privacy manifests,
and Foundation Models imports passed verification. All **654** authoritative
input files and **18** pinned dependency checkouts remained unchanged through
archiving and upload; the generated project stayed unchanged during compilation.
Fourteen stale cached Git object references were repaired using the existing
repository mirrors without changing dependency versions or package sources.

The prior **36** focused chat/API checks (including eight simulator UI flows,
38 executions with parameterized cases), **24** distribution-policy checks,
repository hygiene, catalog invariants, and all **35** catalog download probes
passed. API requests were tested with synthetic HTTP fixtures. This upload pass
did not execute physical-device inference tests or live paid-provider requests.

The verified IPA SHA-256 is
`f50a537b6bc83ced496132bf791879c4669c717f64a88ce98fe9bfe1023fa10b`.
The local checksum was verified before upload. Server checksum verification
was requested, but Apple's API supplied no checksums. Evidence is retained in
ignored `build/appstore/1.0.1-1/` and
`build/testflight-1.0.1-1-2026-10-10/`, including the final
`upload-verification-summary.json`.

[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).
