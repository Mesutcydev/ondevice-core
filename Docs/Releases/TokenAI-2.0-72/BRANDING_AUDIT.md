# Token: Local AI Studio 2.0 (72) — final branding audit

Completed October 24, 2026. All identified app-owned branding findings are resolved. Apple processed the final signed build **2.0 (72)** as **VALID**, and the existing internal **Test** group has access with state **IN_BETA_TESTING**. This build was submitted for App Store review at the owner’s explicit request on October 24, 2026 at 17:36:59 UTC. Apple independently confirms **WAITING_FOR_REVIEW** for both version 2.0 and its review submission. A public App Store release has not occurred. [Submission evidence](Submission/README.md).

- [TestFlight](https://appstoreconnect.apple.com/apps/6774354746/testflight/ios)
- [Published Token website](https://mesut.uk/apps/token)
- [Published privacy policy](https://mesut.uk/apps/token/privacy)
- [Published support page](https://mesut.uk/apps/token/support)
- [Machine-readable audit](Audit/branding-audit.json)
- [Final ASC and TestFlight read-back](completion-verification.json)

## Backup and working project

The original project and shared Git metadata were backed up before modification at `/Users/m/Desktop/ProjectBackups/OnDeviceMax-before-TokenAI-2.0-20261024-184433/`. The original snapshot contained 101,635 files totaling 12,148,395,841 bytes. All **681 source/configuration hashes** were verified again at completion; see [backup verification](backup-source-verification.json). Original ASC metadata, media assignments and all 35 replaced Token screenshots are also saved in that backup. Private reviewer/contact responses remain there, outside these shareable release documents.

The working project is `/Users/m/Desktop/OnDeviceMax/TokenAI.xcworkspace`, scheme `TokenAI`. Its outer directory remains unchanged, and the separate `/Users/m/Desktop/TokenAI` project was preserved. `project.yml` is the source of truth. The [117-file patch](rebrand-changes.patch) compares this task's source/configuration changes against the pre-change snapshot, retaining the checkout's earlier unrelated work. New marketing assets, metadata and website sources are saved in their own project directories.

User-authorized cleanup removed regenerable compiler and dependency-download caches. Source, models, native frameworks, pinned dependency checkouts, successful archives, signed IPAs and dSYMs were retained. Approximately **2 GiB** was available at the final check; available space changes during normal use. Cleanup receipts are under `Audit/` and in the backup.

## App identity and visible branding

| Surface | Final value and evidence |
| --- | --- |
| App display name | **Token: Local AI Studio** |
| Short in-app name | **Token AI** |
| Main bundle | `com.token.TokenAI` |
| Share extension | `com.token.TokenAI.Share`, displayed as Token AI |
| Download activity extension | `com.token.TokenAI.Downloads`, displayed as Token AI Downloads |
| Shared App Group | `group.com.token.TokenAI` |
| CloudKit container | `iCloud.com.token.TokenAI`, Production environment in the signed IPA |
| URL scheme | `tokenai` |
| Shipping targets | Version **2.0**, build **72**, minimum iOS **27.0**, iPhone device family |
| App icon | All **eight** original OnDeviceMax icon, alternate-icon and preview files are byte-identical; [hashes](icon-preservation.json) |
| Splash | Original layout, typography, positioning, 850 ms timing and completion behavior retained; text/accessibility changed to Token AI / LOCAL AI STUDIO |
| Other app-owned identity | Permission translations, share receipts, Live Activities, Shortcuts, diagnostics/network labels, Keychain namespaces, privacy/support/marketing links and legal documents rebranded |
| Bundled notices | Two old-name references in explanatory prose fixed in build 72; copyright and license terms preserved |

The final source scan checked **561 files** and found no unresolved old app-brand references. The IPA scan decoded **137 bundled resource files**, including binary property lists and localized string tables, and found **zero** old OnDeviceMax app-brand references. A broader OnDevice-reference review classified the compatibility symbols and separate products listed below. Generated source/resource/framework membership was compared with the backup and remains equivalent. Dependency pins were preserved; the Podfile lockfile change is its project-reference checksum.

## App Store Connect comparison and update

Source listing: **6818199563**, OnDevice: Max. Existing Token listing: **6774354746**. Editable version ID: `2d111ea6-2fa5-4774-9f20-a511a067573f`.

| Field | Final result |
| --- | --- |
| Name | Token: Local AI Studio across all 11 locales |
| Description, subtitle, promo and keywords | Source feature scope adapted to Token; seven source locales plus four translated existing target locales |
| What's New | First line in every locale is the localized **Added iPhone Duo support** |
| Requirements and capabilities | iOS 27; local chats, Lens, voice, compatible downloadable/imported models, Image Studio, parental controls and optional authenticated Local API; optional provider/web/iCloud behavior disclosed |
| Categories/content rights | Productivity primary, Utilities secondary and source-matching third-party-content declaration |
| Age declarations | Exact source match, including parental controls and 16+ override |
| URLs | Current Token marketing, privacy and support pages |
| Reviewer and beta information | Replaced stale/blank fields with accurate 2.0 instructions; no login required; reviewer notes identify build 72 and separate model downloads |
| Selected build | **2.0 (72)**, ID `3c3c1886-a0c9-4407-9fec-92510b9d6489` |

Fresh target read-back matches every prepared field across **ar-SA, de-DE, el, en-US, es-ES, hi, ja, pt-PT, ro, ru and tr**. The source comparison uses the authoritative source snapshot captured earlier in this session. A final repeat source API read returned 404; the preserved snapshot was used rather than inferring source changes. Original source data and the target read-back are under `Audit/asc/`; the exact prepared copy is in `AppStoreMetadata/TokenAI-2.0/`.

## Screenshots, header and search artwork

The former Token header/search assignments and stale screenshot sets were replaced with Token adaptations of the original OnDeviceMax assets.

- **Header:** 3840 × 1646; **search artwork:** 3840 × 2560. Only the brand-name regions changed to Token AI. Original imagery and all other copy are retained.
- **Screenshots:** six iPhone 6.7-inch and five iPhone Duo images. Nine are unchanged original images; the two sidebar images change only the old app name. Pixels outside the recorded brand regions are identical to their originals.
- English assets are uploaded; the other ten locales use the English fallback, matching the source's screenshot coverage. Old iPad images were removed because the new build declares iPhone support only.
- All 11 uploaded screenshots are **COMPLETE**, their server checksums match local files, and both new header/search placements are **ACTIVE**. OCR and pixel-preservation evidence are saved with the assets.

Files and receipts: `AppStoreScreenshots/TokenAI-2.0/` and `AppStoreCreativeAssets/2026-10-24-TokenAI/en-US/`. [Pixel preservation](../../../AppStoreScreenshots/TokenAI-2.0/pixel-preservation.json) records the exact edited regions.

## Approved live privacy and website changes

The owner explicitly approved publishing the source-matching privacy labels immediately. App Privacy now publishes these three **linked**, **non-tracking** declarations, matching the source:

| Data type | Purpose |
| --- | --- |
| Search History | Other Purposes and App Functionality |
| User ID | App Functionality |
| Other Data Types | App Functionality |

The signed-in ASC UI showed the published status and all three completed declarations with no incomplete-data warning. [Publication receipt](Audit/privacy-comparison.json).

The owner also approved the website publication. Marketing, support and privacy pages now use the original icon, new Token artwork, all 11 screenshots, current system requirements and current feature scope. The privacy policy is the app's **v7**, dated **October 24, 2026**, including optional providers, web tools and iCloud behavior. The marketing page labels 2.0 as a **TestFlight preview**, since the public App Store version has not yet changed.

[Published-page screenshot](Audit/website-published.jpg). All three pages and the public icon/header/search image endpoints returned **HTTP 200**; the three image hashes match the project files. [Live verification](Audit/website-live-verification.json). The scoped `token-ai-pages` deployment serves only the Token routes and icon path. The existing main website Worker's latest deployment is unchanged; [deployment verification](Audit/website-deployment-verification.json). The separate website checkout and its unrelated pending work were preserved. Reproducible sources are in `Web/TokenAI-2.0/`.

## Validation and release evidence

- Repository hygiene, localization validation with 1,131 keys and six translation languages, source packaging gates and **32 packaging-verification tests** passed.
- NativeUIReview compiled, and Argent verified the Token splash, home and sidebar on the dedicated Duo simulator. Evidence is in the preceding [release record](../TokenAI-2.0-71/REBRAND.md). Scoped Argent services were stopped.
- Optimized Release build-for-testing and the production archive passed using per-file compilation with optimization unchanged. Shipping toolchain: **Xcode 27.1 / 27A9275**, iOS 27.1 SDK.
- The final 72 IPA passes app/extension identity, signed distribution, release entitlement and **deep strict code-signature verification**. [Signed IPA receipt](signed-build-verification.json).
- The main signature includes the correct Production CloudKit container, App Group, increased-memory and Extended Virtual Addressing entitlements. Private Cloud Compute is omitted by the standard public release configuration.
- Apple upload completed, processing is **VALID**, internal build state is **IN_BETA_TESTING**, the **Test** group receives the build, and saved What to Test notes match the intended text with Duo support first. [Apple read-back](completion-verification.json).

The successful archive is `/Users/m/Library/Developer/Xcode/Archives/2026-10-24/TokenAI 2.0 (72).xcarchive`. The signed IPA is `build/appstore/2.0-72/signed-export/TokenAI.ipa`; symbols, build products and the earlier successful build 71 are retained.

## Deliberate remaining references and testing limits

These references remain for an explicit reason and are not the Token app's old visible identity:

- `OnDeviceUI`, `IOSLocalLLM`, `OD*`, compatibility types, persisted model/cache/preference formats, `ondevice-code` and `_localllm._tcp` preserve working imports, protocols and stored data formats.
- **OnDevice Mac** and **OnDevice: AI Image Studio** identify separate companion/promoted products. Their names and destinations remain accurate.
- **SiteAgent** is the existing shared GitHub OAuth registration, explained in the app. Token credentials use their own namespace.
- Original assets, backup folders, historical release documents, source paths and upstream licensing retain provenance and required attribution.

The UI fixture does not exercise production CoreAI inference. Physical model inference/downloads, camera/audio, image generation, an installed upgrade from Token 1.x, optional iCloud sync and Local API acceptance remain beta validation areas. These limits are disclosed in the tester/reviewer notes. No unresolved branding or publication finding remains. App Store review was subsequently requested by the owner and submitted successfully; public release awaits Apple’s review outcome.
