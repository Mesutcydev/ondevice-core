# TestFlight reasoning, compaction and repository tools — 2026-10-10

Apple confirms **OnDevice Max 1.0.1 (3)** is **VALID** and **IN_BETA_TESTING**
for the existing internal **Me** group, which has access to all builds. English
What to Test notes were published and verified. The external state remains
`READY_FOR_BETA_SUBMISSION`; public App Review was not submitted.

- App: `6818199563`, bundle `com.mesutcydev.ondevicemax`.
- Owner team: `PUH4GMFV56`.
- Build ID: `3eb710a0-6df0-42b1-83ff-fbfb7172eff2`.
- Apple build upload time: **October 10, 2026, 21:43:15 Europe/Istanbul**.

The update retains reasoning throughout streaming, tool handoffs, completion
and Stop, with a collapsed disclosure that can be opened while live. It keeps
the timed row, reply bar, top model picker and existing scrolling. The context
compaction notice now shares the composer's edges, aligns its scaled icon to
the first text line and wraps correctly in narrow and large-text layouts.

Eight additional selected-repository tools provide metadata, branch listing,
numbered file ranges, staged moves, secret scans/redaction, bounded history
audits and workflow status. Tools remain off by default and retain approval,
cancellation and scope checks. Detected credentials are masked in model-facing
results; draft file snapshots use device-only Keychain-backed encryption.
See the [reasoning and repository QA record](REASONING_REPO_SECURITY_QA_2026-10-10.md).

## Candidate verification

The app and share extension both report **1.0.1/build 3**, built with shipping
Xcode **27A266a** and `iphoneos27.0`. A fresh signed archive and App Store export
passed resource, privacy manifest, profile, signature, entitlement and
FoundationModels symbol verification. Both package lockfiles were retained.
All **665** captured authoritative source files and **18** pinned dependency
checkouts stayed unchanged through packaging and upload. The compiled generated
project was also verified unchanged.

The preceding focused QA passed **45 logical tests** (47 executions including
parameter cases), the production/QA compile gates and repository validation.
The packaging run repeated repository validation, public catalog invariants
and all **35** exact-revision download probes successfully. Simulator tests use
the real shared presentation and mocked transport; they do not establish live
GitHub account policies, physical-device inference, camera/voice or thermals.
The remaining public-release conditions in
[the release audit](APP_STORE_RELEASE_AUDIT_2026-10-09.md) remain applicable.

The new draft encryption uses Apple's CryptoKit AES-GCM and Security Keychain;
the existing non-exempt-encryption metadata was retained. Apple's
[export documentation guidance](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
requires no App Store Connect documentation for encryption limited to the Apple
operating system. The new component uses the operating system's implementation.

IPA: `build/appstore/1.0.1-3/export/OnDeviceMax.ipa` (**85,502,523 bytes**).
SHA-256: `f19d70a3254d4758d56d9762b08657c9d74619995c4043c36744bd8ebf6f3f0f`.
The local checksum was verified before upload. Server checksum verification
was requested, but Apple's API provided no checksum.

Evidence is retained under ignored `build/appstore/1.0.1-3/` and
`build/testflight-1.0.1-3-2026-10-10/`, including
`upload-verification-summary.json`, the compiled source fingerprints, final
Apple processing/beta state, and the verified English notes. Prior release
archives, exports and QA evidence were preserved; only generated build caches
were cleared to recover archive working space. No credentials or signing keys
were copied into the repository.

[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).
