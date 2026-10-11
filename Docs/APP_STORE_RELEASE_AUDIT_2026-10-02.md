# OnDevice Max release audit — 2026-10-02

Target: public iOS App Store release, version **1.0 (81)**. Existing App Store
Connect app: **OnDevice Max**, Apple ID `6818199563`, bundle ID
`com.mesutcydev.ondevicemax`, owner team `PUH4GMFV56`.

**Status: English listing and six screenshots saved to App Store Connect;
verified build 81 attached; public release remains pending.** The replacement
`new27` API key authenticates successfully. Support and privacy pages are live
on ondevice.fun. No review submission or App Store release was performed.
The user reviewed and approved the ASC privacy nutrition labels. All three
categories are saved; the final publish attestation awaits confirmation.

This report covers the current working tree, which includes substantial
pre-existing changes. It does not certify every model's rights or behavior.
Physical-device acceptance and commercial-license confirmations are reserved
for the final release step at the user's request.

## Screenshots and listing

Six original native screenshots are prepared for English (US), in this order:

1. Conversation
2. Saved chats
3. Leading sidebar
4. Model library
5. Voice selection
6. Image Studio

Files: `AppStoreScreenshots/1.0-81/en-US/iphone-6.9/`. The preview is
`AppStoreScreenshots/1.0-81/preview.html`; the upload-order ZIP is
`AppStoreScreenshots/1.0-81/OnDeviceMax-1.0-81-en-US-iPhone-6.9.zip`.
The manifest records each file's SHA-256 and provenance. All six PNGs are
1320 × 2868, 8-bit RGB, without alpha. This is an accepted iPhone 6.9-inch size.
[Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

The screenshots use the production `OnDeviceUI` package and
`ImageGenerationView` in the isolated `QA/NativeUI` host. Conversations and
model availability are illustrative fixture state. No inference, generated
image, audio, camera capture, or device-performance measurement was performed.
The fixtures omit fabricated storage/performance values and retain the current
leading-sidebar navigation. This is appearance evidence only.

English listing copy is prepared under
`build/appstore-audit-2026-10-02/listing/`: name, subtitle, promotional text,
description, keywords, support URL, copyright, categories, and review notes.
Character limits pass. `en-US.json` is a local task record, not an ASC bulk
metadata-import schema. The individual `.txt` files support portal entry.
The canonical `listing/metadata/` files pass `asc metadata validate` with zero
errors or warnings. A fresh `remote-after/` pull matches every prepared field:
name, subtitle, privacy URL, description, keywords, promotional text, support
URL and marketing URL. Categories are Productivity and Utilities; copyright
and reviewer instructions are saved. The existing same-app TestFlight reviewer
contact was reused, and sign-in is not required. Private contact details are
excluded from this report.

All six uploaded screenshot assets report `COMPLETE`, in the intended order.
ASC displays them as the 6.9-inch set and inherits them for smaller iPhones.
Evidence: `screenshots-upload.json`, `screenshots-remote.json`,
`metadata-applied.json`, `remote-after/`, and `asc-proof/` beneath the audit
output directory. ASC version ID: `9c6688e5-8a6f-4072-ad0c-b7ae9c84cebd`.

Published URLs, also saved in ASC:

- Support: <https://ondevice.fun/support/>
- Privacy: <https://ondevice.fun/privacy/>
- Marketing: <https://ondevice.fun/>

The existing Cloudflare Workers website checkout is `/Users/m/ondevicewebsite`.
Commit `b3bd546` adds readable support/privacy pages and corrects blanket
zero-network claims in all three homepage locales. Cloudflare's build check
passed, and both public pages were verified in the browser. Desktop/mobile
layout, canonical URLs, local assets, anchors, translations and sitemap checks
passed. The privacy page covers optional providers, local-network features,
iCloud, local retention, parental controls, and website/support processing.

## ASC authentication

The user approved replacing the unusable key `8FJ22HYK77`. It is revoked.
Safari downloaded replacement `new27`, key ID `3DHH359WQY`, with Admin access.
Issuer ID: `5ddc2a8a-c374-4f06-b9bd-916f198652be`.
The private file is `/Users/m/.blitz/AuthKey_3DHH359WQY.p8`, mode `0600`.
The active CLI configuration now defaults to `new27`; the previous profile
and unrelated team key were preserved. Authenticated app lookup confirms
Apple ID `6818199563` and bundle ID `com.mesutcydev.ondevicemax`.
No private-key material is included in repository files or this report.

## Validation and packaging

| Check | Result | Evidence |
| --- | --- | --- |
| Repository source/hygiene validator | Passed | `build/appstore-audit-2026-10-02/repository-validation.log` |
| App Store source policy verifier | Passed | `python3 scripts/verify_appstore.py --source` |
| Public catalog invariants | Passed | `build/appstore-audit-2026-10-02/public-catalog.log` |
| Distribution/profile and candidate metadata tests | 19 passed | `build/appstore-audit-2026-10-02/distribution-policy-tests.log` |
| Screenshot QA host build, shipping Xcode 27 | Passed | `build/appstore-audit-2026-10-02/screenshot-harness-build.log` |
| Production Release build-for-testing, generic iOS, signing disabled | Passed; tests compiled, not executed | `build/appstore-audit-2026-10-02/production-build-for-testing.log` |
| Compiled app/extension metadata and resource policy | Passed for 1.0 (81), `27A266a` | `build/appstore-audit-2026-10-02/compiled-bundle-verification.log`; this is not distribution-signature verification |
| Signed 1.0 (81) distribution export | Passed fresh independent verification; IPA hash matches upload record | `build/appstore-audit-2026-10-02/signed-export-81-verification.log` |
| ASC build 81 processing and attachment | `VALID`; attached to version 1.0 | `build/appstore/1.0-81/testflight-status.json`; fresh `builds-current.json` and portal verification |
| Physical-device runtime and distribution acceptance | Pending final step | No hardware inference or share/iCloud checks performed in this pass |

Shipping toolchain: Xcode 27, build `27A266a`. The selected beta build
`27A5218g` is not used for the candidate checks.
[Apple release record](https://developer.apple.com/news/releases/?id=09142026h).

The App Store verifier now checks requested version, build number, toolchain,
and iPhoneOS SDK/platform in both app and share extension. The archive/export
script passes those expectations to both bundle checks. Tests include stale
build 80, wrong version, beta toolchain, missing metadata, and Simulator/Catalyst
rejection. Both bundles in the preserved 1.0 (80) export report shipping
`27A266a`, but that artifact correctly fails the new 81 expectation. This pass
inspected its metadata; it did not repeat its full distribution-signature audit.

An initial archive preflight in this audit stopped for insufficient disk space.
A separate release workflow subsequently produced and uploaded build 81 on
2026-10-02. Fresh ASC lookup reports `VALID`, build ID
`492e8259-b147-46cc-8185-ca3c5a33839f`. Its export is
`build/appstore/1.0-81/export/OnDeviceMax.ipa`, SHA-256
`0a3933412fc2df95475ca35a90f8a63c970e8a076518e1e8cb59301298d4d3e5`.
This audit independently checked that hash and the extracted distribution
bundle with owner team, version 1.0, build 81, shipping toolchain `27A266a`,
signatures, entitlements, profiles and resource policy. Verification passed;
temporary extraction files were removed. The previous ASC build 79 attachment
was replaced with verified build 81. No duplicate upload was attempted.

## Final release gates

Use the detailed [2026-10-01 compliance audit](APP_STORE_COMPLIANCE_AUDIT_2026-10-01.md)
as the baseline for unresolved findings. This pass does not overturn them.

- **Exact model rights:** confirm artifact/revision-specific commercial-use
  conditions, attribution, restrictions, and territories, including Turbo and
  Liquid AI requirements. Public FastVLM/Youtu guards and frozen source
  revisions establish exclusion/provenance, not complete license clearance.
- **Generated-content behavior and age rating:** validate effective controls
  and abusive/bypass cases on the public candidate. A parent PIN controls
  access to Image Studio; it does not classify prompts or output.
- **Privacy declarations:** the corrected public policy is published. Verify
  all enabled providers and reconcile Xcode privacy manifests/report with ASC.
  The user approved `listing/privacy-approved.json`: linked search history
  (App Functionality and Other Purposes), User ID and Other Data Types
  (App Functionality), with no tracking for any category. Those responses are
  saved in ASC under `asc-privacy-nutrition-labels`; publishing requires the
  final accuracy/compliance attestation shown by Apple.
- **Hardware and CloudKit:** validate downloads/inference, voice/camera,
  cancellation/unload, memory/thermal refusals, share receipt, background API
  shutdown, parental controls, and the production CloudKit schema on iPhone.
- **Portal declarations and distribution:** complete accurate privacy/age/rights
  answers, configure pricing/territory availability after license clearance,
  and check account agreements before final review submission. Fresh canonical
  `asc validate` reports 24 blocking checks: 22 unanswered age-rating fields,
  content-rights declaration, and app availability. Privacy-label publication
  is separate and is not covered by that CLI completeness check.

App Store preparation is not approval of model rights or generated-content
safety. The relevant completeness, metadata, rights, privacy, and content rules
are in [Apple's App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## Changes in this pass

- Added QA-only App Store scene presets with public catalog identities and
  documented their capture/provenance limits.
- Corrected the Models fallback label from “Storage not measured used” to
  “Storage not measured”; measured storage retains its “used” suffix.
- Added candidate version/build/toolchain checks to App Store bundle
  verification and seven meaningful metadata regression cases.
- Prepared the screenshot gallery/ZIP and listing drafts in ignored output
  directories. Generated artifacts and credentials remain outside Git.
- Saved the listing, reviewer information and screenshots in ASC; replaced
  the stale build attachment with independently verified build 81.
- Published support/privacy pages in the separate website repository and
  configured the user-approved replacement ASC API key.

App repository source changes remain uncommitted. Website changes were committed
and deployed separately as `Mesutcydev/ondevice` commit `b3bd546`.
