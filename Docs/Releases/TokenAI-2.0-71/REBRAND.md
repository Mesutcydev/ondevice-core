> Historical build 71 record. The completed build 72 audit, TestFlight status, artwork, privacy-label publication and website publication are recorded in [the final branding audit](../TokenAI-2.0-72/BRANDING_AUDIT.md).

# Token: Local AI Studio 2.0 (71)

The working OnDeviceMax checkout was rebranded in place. Open `TokenAI.xcworkspace` and select the `TokenAI` scheme. The app's Swift module and internal source directories remain `IOSLocalLLM` so existing imports, runtime integration and tests stay intact. The separate `/Users/m/Desktop/TokenAI` source tree was not replaced.

## Backup and storage cleanup

The pre-change project and its shared Git metadata are saved at `/Users/m/Desktop/ProjectBackups/OnDeviceMax-before-TokenAI-2.0-20261024-184433/`. The original snapshot contained 101,635 files, 12,148,395,841 bytes. All 681 recorded source/configuration hashes still match after the user-authorized cleanup. Regenerable compilation caches were removed from the project and corresponding backup locations; source, models, native frameworks, dependencies, app products, archives and IPAs were retained. See the backup's `verification.json`, `source-hashes-before.json`, `storage-cleanup.json` and `RESTORE.txt`.

## Branding

- App display name: **Token: Local AI Studio**; in-app short name: **Token AI**.
- App: `com.token.TokenAI`.
- Share extension: `com.token.TokenAI.Share`.
- Download activity extension: `com.token.TokenAI.Downloads`.
- Shared App Group: `group.com.token.TokenAI`.
- CloudKit container: `iCloud.com.token.TokenAI`.
- URL scheme: `tokenai`, including share-inbox and download activity routes.
- All three shipping targets use version 2.0 and build 71.
- The original OnDeviceMax AppIcon, alternate icon and both previews are unchanged; eight asset files are recorded in `icon-preservation.json`.
- The original splash layout, serif typography, positioning, timing and callback are unchanged. Only its two visible strings and accessibility label were rebranded. See `splash.png` and the isolated patch.
- App-owned branding, localized permission descriptions, share receipts, Live Activity labels, Shortcuts labels, networking identity, Keychain namespaces and legal links now use Token AI.
- Privacy/support links match the existing TokenAI URLs. The detailed OnDeviceMax in-app legal disclosures were retained and rebranded, with legal version 7. Companion Mac product names, the separate Image Studio promotion and upstream license attribution retain their correct identities.

Generated Xcode source/resource/framework membership was compared with the backup and is unchanged. Package pins are retained, and the CocoaPods lockfile differs only in its Podfile checksum after the project-reference rename. `project.yml` remains the source of truth. `rebrand-changes.patch` isolates this task's changes from the checkout's pre-existing work.

## App Store Connect

Source app: `6818199563` (OnDevice: Max). Target app: `6774354746` (Token AI).

The existing editable 1.5 version record was changed to **2.0**; its record ID is `2d111ea6-2fa5-4774-9f20-a511a067573f`. The new version remains **PREPARE_FOR_SUBMISSION**.

Descriptions, promotional text, keywords and subtitles follow the source listing. Token branding and privacy/support/marketing URLs are applied. Seven source locales and four pre-existing target-only locales are represented across 11 languages. The four additional descriptions were translated to match the source's feature scope. Updated release notes begin with the localized equivalent of **Added iPhone Duo support** in every locale. The comparison and exact uploaded text are in `asc-metadata-diff.json` and `AppStoreMetadata/TokenAI-2.0/`.

The English product-page header and App Store search-results image assignments were removed. All 11 localizations were checked for both placement types afterward. Original library media remains available; assignment and media records are backed up. The secondary Utilities category, third-party-content declaration, parental-control declaration and age-rating override were matched to OnDeviceMax.

Read-back verification confirms every prepared field matches the saved ASC values. See `asc-verification.json`. App Store review has not been submitted. The old 1.5 build selection was cleared from the 2.0 draft; the verified 2.0 (71) IPA is uploading to the existing internal Test group.

## Validation

- Repository hygiene and localization validation pass: 1,131 keys and six requested translation languages.
- App Store source validation and 32 packaging-verification tests pass.
- NativeUIReview simulator build passes. Argent verified the Token-branded splash, chat home and sidebar using the production UI package on the dedicated Token AI Duo simulator. This fixture does not exercise model inference.
- The first optimized device compile stopped because storage filled. Task-generated caches and completed audit caches were cleared before retrying with per-file Release compilation and the same optimization level.
- Optimized Release build-for-testing and production archive both pass with per-file Release compilation and optimization unchanged.
- The archive was signed with explicit release entitlements and exported through Xcode with manual distribution profiles. The final IPA passes signed distribution validation for the app and both extensions, exact 2.0 (71) identity, Xcode 27A9275, Production CloudKit, and deep strict code-signature verification. See `signed-build-verification.json`.
- Completed compilation caches were cleared again after archiving; the archive, signed IPA, dSYMs, products and pinned dependencies are retained. Disk returned to approximately 4.4 GiB free.

The production CoreAI dependency requires the device SDK. Physical inference and an installed upgrade from TokenAI 1.x were not exercised. The Developer Portal app ID has the Token iCloud container, increased-memory limit and Extended Virtual Addressing enabled. A fresh main distribution profile and existing Share plus new Downloads profiles were verified and installed. Private Cloud Compute is omitted by the standard release entitlement configuration. Physical inference, installed-upgrade retention and optional iCloud sync remain beta validation areas.
