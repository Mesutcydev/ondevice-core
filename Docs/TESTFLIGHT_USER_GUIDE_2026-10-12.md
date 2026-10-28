# TestFlight visual user guide — 2026-10-12

OnDevice: Max **1.0.1 (5)** is processed **VALID** and available for internal
TestFlight testing (**IN_BETA_TESTING**). Apple build ID is
`7f054d2e-e0ca-4c0f-8ea4-c1b30747c124`, app `6818199563`, bundle
`com.mesutcydev.ondevicemax`, owner team `PUH4GMFV56`. Apple records the build
upload at **October 12, 2026, 14:22:36 Europe/Istanbul**. English What to Test
notes were published and read back successfully. External state is
`READY_FOR_BETA_SUBMISSION`; the existing internal Me group has access to all
builds.

Settings → User Guide now presents **14 topics and 61 walkthrough steps**, with
eleven bundled app captures, focus highlights, model-state explanations, and
flow diagrams. Topics cover chat, models, Lens, voice, images, classifiers,
API providers, GitHub, the local API, privacy, settings, and troubleshooting.
Native Previous/Next controls and a step picker support navigation. At
accessibility text sizes, navigation uses compact arrow buttons with explicit
VoiceOver labels. The guide distinguishes local processing from optional
network features. Image provenance is in
[UserGuideSourceManifest.json](Images/UserGuideSourceManifest.json).

The production guide views passed the NativeUI content contract and three
simulator UI flows covering navigation boundaries, dark model/privacy diagrams,
and reachable navigation at the largest accessibility text size in a 320-point
layout. The navigation and large-text flows passed again after the footer
adjustment. Captures were visually inspected. These tests exercise the production
SwiftUI views with the QA host; physical-device inference was not exercised.

Both the app and share extension report **1.0.1 (5)**, built with shipping Xcode
**27A266a**. The archive, signed App Store export, owner-team distribution
profiles, resource checks, privacy manifests, required entitlements, and
Foundation Models import checks passed. All eleven guide images are present in
the archived asset catalog, which matches the exported IPA. The **550** recorded
source files stayed unchanged through archiving and upload, and all **18** package
checkouts matched their locked revisions and were clean. Repository hygiene,
catalog invariants, and all **35** catalog download probes passed.

The local Apple Development identity failed root-app signing. This archive used
a temporary configuration that selects manual signing only for the app and share
extension, with the existing Apple Distribution identity and two new unmanaged
App Store profiles for the existing bundle IDs. Export used automatic App Store
distribution signing. The temporary configuration and profiles remain in ignored
build evidence; permanent signing settings in project.yml remain automatic.

IPA SHA-256:
`e1723ebdcfb098fe3b1d46e67f0d6e9007ea96cb54534b087fc6a758efd2b852`.
The local checksum was verified before upload and after processing. Server
checksum verification was requested, but Apple's API supplied no checksums.
Evidence is retained in ignored `build/appstore/1.0.1-5/` and
`build/user-guide-release-2026-10-12/`, including
`upload-verification-summary.json`.

[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).
