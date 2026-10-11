# TestFlight memory fixes — 2026-10-10

The owner requested a new TestFlight build after the
[memory management audit](MEMORY_MANAGEMENT_AUDIT_2026-10-10.md).
Candidate: **OnDevice: Max 1.0 (84)**, app `6818199563`, bundle
`com.mesutcydev.ondevicemax`, owner team `PUH4GMFV56`.

**Apple processing is VALID; internal TestFlight state is IN_BETA_TESTING.**

## Changes and validation

This beta includes coordinated assistant loads, cancellation and teardown
ordering, stale vision-load protection, bounded loading caches, fresh memory
admission, and allocator accounting fixes. Existing working-tree changes are
retained. The app and share extension both use build 84 from `project.yml`.

- The audited source passed **10** load/lifecycle tests, **140** memory checks,
  and **6** quantization policy tests. Its final production test compile passed.
- A fresh shipping Xcode **27A266a** Release archive and signed App Store
  export passed for build 84 with the public model policy.
- Repository hygiene, model catalog invariants and all **35** catalog download
  paths passed. Foundation Models imports match the selected SDK.
- The signed IPA passed app/extension version, resource, signature, profile,
  owner-team and distribution-entitlement verification.
- All **819** captured source inputs remained unchanged through packaging.
  Both package lockfiles match; all **18** remote checkouts have their exact
  pinned revisions and clean working trees.

The source fingerprint, regenerated project fingerprint, archive/export logs,
signature verification and upload evidence are retained under ignored
`build/appstore/1.0-84/`.

IPA: `build/appstore/1.0-84/export/OnDeviceMax.ipa` (84,107,724 bytes).
SHA-256: `d6cf22c2f9f66d251a87416896e175e90b57886ad02a23640555dc5b09247315`.
The local checksum was checked before upload. The upload requested server
checksum verification, but Apple's API supplied no checksums.

## Device acceptance

The owner reported **“It works fine now”** after TestFlight delivery and then
approved submission to App Review. This records owner feedback; no automated
physical-device inference test was executed during this run. Suggested
regression coverage includes the imported MiMo model, repeated model switches,
load cancellation, background/foreground recovery, and chat/vision afterward.
The earlier device-test installation rejection remains documented in the audit.
The supplied unclean-exit trail alone does not establish a Jetsam diagnosis.

## Distribution

Apple confirms build ID `bb544351-caef-4494-865c-e5d37140288e`, version
**1.0 (84)**, iOS. Upload timestamp: **October 10, 2026, 08:43:57
Europe/Istanbul**. English test notes were published and verified. The final
summary is `build/appstore/1.0-84/upload-verification-summary.json`.

The existing internal **Me** group has access to all builds. External state is
`READY_FOR_BETA_SUBMISSION`. Build 83's public App Review submission was
withdrawn before this release. This upload supplies a beta for verification.
[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).

## App Review submission

After the owner's explicit approval, build **84** replaced build 83 on App
Store version **1.0** (`9c6688e5-8a6f-4072-ad0c-b7ae9c84cebd`). App Store
Connect's submission checks reported zero blockers. The new review submission
`4886cf50-4729-48ec-81ee-8c6a57a6410f` was accepted on **October 10, 2026,
08:58:59 Europe/Istanbul**.

Fresh independent lookups confirm both the version and review submission are
**WAITING_FOR_REVIEW**, with build ID `bb544351-caef-4494-865c-e5d37140288e`
still attached. Submission evidence is retained locally under ignored
`build/app-review-84-2026-10-10/`, including
`submission-verification-summary.json`.
