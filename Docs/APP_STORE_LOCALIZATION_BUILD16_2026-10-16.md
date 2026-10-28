# Localization release — October 16, 2026

Candidate: **OnDevice: Max 1.0.1 (16)**, app `6818199563`, bundle
`com.mesutcydev.ondevicemax`, team `PUH4GMFV56`.

The owner requested a fresh upload and App Review resubmission after adding
Hindi, German, Spanish, Arabic, Turkish, and Japanese localization. The existing
App Store version was renamed from 1.0 to 1.0.1 to match the current binary.
All seven metadata locales, including English, were read back and preserved.

## Candidate verification

- Shipping Xcode **27.1 (27A9275)**, iPhoneOS **27.1** SDK. Apple lists this
  [shipping release](https://developer.apple.com/news/releases/?id=10152026a)
  and supports its toolchain for
  [App Store uploads](https://developer.apple.com/help/app-store-connect/release-notes/).
- App, share extension, and download activity extension all use **1.0.1 (16)**.
- Signed archive and manual App Store distribution export pass bundle,
  provisioning, entitlements, framework, and signature verification.
- All **1,196** release input hashes remain unchanged through packaging and
  after upload. All **18** package checkouts match their locked revisions.
- Compiled localization checks pass for **1,090 catalog keys**, six requested
  languages, the app, shared UI resource bundle, both extensions, and permission
  strings. Long-form guides and some advanced diagnostics remain English.
- Repository validation, **32** distribution-policy tests, all **36** catalog
  download probes, and the six pinned MiniCPM file probes pass. Probes request
  small byte ranges; model weights were not downloaded for this release.
- All **170** imported FoundationModels symbols exist in the selected SDK;
  no deprecated-renamed symbols are imported.
- The retained localization simulator checks cover all six sidebar languages
  and live English-to-Arabic switching with a retained draft and mirrored
  layout. The earlier package suite passed **16** tests. These are retained
  results for the localization source; this release does not claim a new
  physical-device inference test.

IPA: `build/appstore/1.0.1-16/export/OnDeviceMax.ipa`, **92,660,616 bytes**.
SHA-256: `1c1be04a6918b3d8dd9595a18329ad1537279329be2e6767dbe505932544a728`.
The hash was checked locally after upload. Apple's API supplied no remote
checksum, so remote checksum verification is not claimed.

## App Store Connect

The signed upload was committed on October 16 at **13:48:27 Europe/Istanbul**.
Upload ID: `e8df9569-d590-43ec-a28a-accc3c0dd7e0`.

Apple processing is **VALID**. Build ID:
`e8df9569-d590-43ec-a28a-accc3c0dd7e0`.

Version **1.0.1 (16)** was submitted for public App Review on October 16 at
**14:04:11 Europe/Istanbul**. Submission ID:
`1f0aa2a3-17b6-48b5-8e82-1c7917bb5847`. Fresh reads confirm the version and
submission are both **WAITING_FOR_REVIEW**, and the selected build is **16**.
All seven localized metadata records were compared to their source files again
after submission and match.

The final readiness check had zero blocking errors. Its seven What's New
warnings come from treating version 1.0.1 as an update, although this is still
this app's first App Store release. Apple explicitly refuses editing that
field for this version. The attempted release-note drafts are retained in
ignored evidence, and the canonical metadata omits the read-only field. Apple
accepted the review submission. Existing reviewer contact information and
release policy were preserved; review notes explain language switching and the
remaining English help text.

Evidence: ignored `build/localization-release-2026-10-16/` and
`build/appstore/1.0.1-16/`. Localized store metadata is retained under
`AppStoreMetadata/localizations/`.
