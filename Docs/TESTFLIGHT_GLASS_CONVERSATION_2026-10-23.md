# TestFlight — conversation glass update, October 23, 2026

**OnDevice: Max 1.0.1 (19)** is uploaded, Apple processing is **VALID**, and
internal TestFlight state is **IN_BETA_TESTING**. The existing **Me** group has
access to the build. English What to Test notes were published and read back.

App `6818199563`, bundle `com.mesutcydev.ondevicemax`, team `PUH4GMFV56`.
Build ID: `81ca350e-2210-445f-b714-b2445d2e82b7`. Apple upload timestamp: **2026-10-23T01:04:50+03:00**.
[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).

The candidate includes the native glass composer, title capsule and compact
conversation details sheet, ordered expandable tool activity, full output
inspection/copying, and saved conversation expansion state. Existing model,
pin, search, sharing and deletion routes are retained. The
[design audit](OPENCODE_SESSION_ADAPTATION_2026-10-22.md) records the reference
adaptation and the limits of the retained simulator evidence.

## Release verification

- Shipping Xcode 27.1 (`27A9275`), iPhoneOS 27.1 SDK; checked against Apple's
  [shipping release listing](https://developer.apple.com/news/releases/?id=10152026a).
- Fresh Release archive and signed App Store distribution export pass.
  App and both extensions use **1.0.1 (19)**. Distribution signatures,
  provisioning profiles, capabilities, privacy/resource and policy checks pass.
- **32** distribution-policy tests and repository hygiene checks pass.
- **1,131** localization keys and all six requested languages verify in the
  compiled app, shared UI package and both extensions.
- **36** catalog download probes and six pinned MiniCPM file probes pass using
  small ranged requests. No model weights were downloaded for these checks.
- All **170** imported FoundationModels symbols exist in the selected SDK;
  no deprecated-renamed imports are used. Native runtime identity checks pass.
- **1,209** release input hashes and all **18** pinned dependency revisions
  remain unchanged through packaging and after upload. The IPA's local
  SHA-256 matches before and after upload.
- The final simulator UI rerun was interrupted, as recorded in the design
  audit. This release does not claim a new physical-device inference test.

IPA: `build/appstore/1.0.1-19/export/OnDeviceMax.ipa`, **94,123,147 bytes**.
SHA-256: `198fbfd8ced2c9c8f0fa3fc900b02a418258a1bad0e615d675970198c5c5fc7d`. Apple's upload API supplied no remote checksums;
remote checksum verification is not claimed.

Evidence is retained under ignored `build/testflight-glass-2026-10-22/` and
`build/appstore/1.0.1-19/`. No public App Review submission or new tester
invitations were added.
