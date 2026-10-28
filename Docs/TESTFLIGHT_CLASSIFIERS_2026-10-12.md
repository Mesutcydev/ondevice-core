# TestFlight classifier update — 2026-10-12

OnDevice: Max **1.0.1 (6)** is processed **VALID** and **IN_BETA_TESTING**.
The existing internal **Me** group has access to all builds. English What to
Test notes were published and read back successfully. Apple records the upload
at **October 12, 2026, 21:40:19 Europe/Istanbul**. External state is
`READY_FOR_BETA_SUBMISSION`.

- App: `6818199563`, bundle `com.mesutcydev.ondevicemax`.
- Owner team: `PUH4GMFV56`.
- Apple build ID: `170b67d9-f347-4808-9afe-a1499e980baa`.

The update adds 13 portable classifier downloads across Julia-1, Laya English,
Laya Multilingual and FastViT, with GGUF/Core ML adapters. The classifier
workspace includes saved task definitions, photo/file input for fixed image
categories, ranked results and exports with model/source information. Downloads
and runtime activation retain the shared memory, thermal and cancellation
paths. The visual User Guide from build 5 remains included.

See the [classifier audit](CLASSIFIER_APP_AUDIT_2026-10-12.md) for the catalog,
runtime contracts and 56 focused checks. These include real cached Mac
inference and native UI fixtures; physical iPhone inference and accuracy
benchmarking remain separate acceptance work.

## Candidate verification

Both the app and share extension report **1.0.1 (6)**, built with shipping
Xcode **27A266a**. The signed archive and App Store export passed resources,
privacy manifest, distribution-profile, signature, entitlement and Foundation
Models import verification. The IPA's embedded llama runtime UUID matches the
pinned **b11558** device slice and archived framework.

All **1,035** fingerprinted source and native input files remained unchanged
through archiving and export, and were checked again before upload. All **18**
package checkouts matched their locked revisions and were clean. Repository
hygiene, public catalog invariants, all **36** Core AI catalog download probes,
and all **13** portable classifier download probes passed. The Mac-only Julia
512-token entry's size was corrected to the exact pinned subtree size during
the release checks.

The archive reused the owner's valid existing Apple Distribution identity and
unmanaged App Store profiles through an ignored temporary configuration.
Export used automatic App Store distribution signing and Production CloudKit.
Permanent signing settings remain automatic. The earlier interrupted archive
attempt and previous release artifacts were preserved.

IPA size: **88,788,370 bytes**. SHA-256:
`ad55703c5f47f326c7b34ead99e15053c83644dcb9c75fffb16da105a2818159`.
The local checksum was verified before upload and after Apple processing.

Evidence is retained under ignored `build/appstore/1.0.1-6/` and
`build/classifier-release-2026-10-12/`, including the distribution verification,
native-runtime UUID checks and `upload-verification-summary.json`. No model
weights or signing credentials were added to Git.

[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).
