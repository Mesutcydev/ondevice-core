# Token: Local AI Studio 2.1.2 (84) — TestFlight

Build **2.1.2 (84)** was uploaded to App Store Connect on 2026-10-28 and reported **VALID** with internal beta state **IN_BETA_TESTING** (auto-notify on). External testing remains **READY_FOR_BETA_SUBMISSION**; nothing was submitted for beta review or App Review in this run.

- TestFlight: <https://appstoreconnect.apple.com/apps/6774354746/testflight/ios>
- Build ID: `13fb6c11-fa67-4fb5-ba75-b2b115bd66c6`
- IPA: 94,248,233 bytes, SHA-256 `eb143db75e90657fe79b392372306ed90832a032ee7fa0daa4df303893118f4c`
- Receipt: [upload-receipt.json](upload-receipt.json)

## Why 2.1.2 and not 2.1.1

The first attempt of this work was built as 2.1.1 (83). Apple rejected the upload with **90186** (the 2.1.1 pre-release train is closed) and **90062** (CFBundleShortVersionString must be higher than the previously approved 2.1.1). No 2.1.1 (83) build exists. `MARKETING_VERSION` and all three `CFBundleShortVersionString` entries in `project.yml` were moved to **2.1.2** and the build number to **84**. `project.yml` is the source of truth; `xcodegen` rewrites the checked-in plists from it.

## What is in the build

| Area | Change |
| --- | --- |
| Image model picker | Split into **On device** / **Discover** so downloadable models are no longer mixed into one list. Stable identifiers, progress, and an explicit Download row per model. |
| Downloads | `ModelDownloadCenterView` now renders the shared model snapshot (`ODModelDownloadsView` over `store.models`). Image, Core AI, classifier and Hub language-model transfers all appear with progress plus the pause / resume / cancel actions each model supports. Failed transfers keep their error text. |
| Model library | The **Image** capability filter switches to Discover when no image model is installed, `ODImageModelLibrary` projects image-service state into the same library rows as every other model, and the capability row shows a scroll indicator because Image/Tools sit beyond the first screenful. |
| HTML preview | Assistant HTML code blocks gain a **Preview** action that runs the markup in a sandboxed `WKWebView` with a per-artifact origin and a compiled content rule list that blocks `http(s)`/`ws(s)`, with Preview/Source modes, reload and stop. |

Source diff for this baseline: 21 tracked files changed (+428 / −363) plus five new files (`ODImageModelLibrary.swift`, `ODModelDownloadsView.swift`, `ImageModelDownloadFlows.swift`, `ResponseRenderingFlows.swift`, this directory).

## Verification actually run

Simulator `EFD851BF` (iPhone 17 Pro, iOS 27.0), `QA/NativeUI`:

| Selection | Result |
| --- | --- |
| `ImageModelDownloadFlows` (3 tests) | passed |
| `ResponseRenderingFlows` (HTML preview) | passed |
| `testClassifierCatalogIsVisibleAndDownloadRoutesToHost`, `testUnifiedModelAppearsInBothFiltersAndUseChoosesWorkspace`, `testModelsScreenSurvivesInvalidDownloadProgress`, `testImageExamplesSetupAndDraftSurviveWorkspaceNavigation`, `testRedesignedLibraryFiltersAndStorage` | passed |
| `HostContracts` (whole bundle) | 91 passed; `testProductionKeychainRoundTrip` fails in the simulator (`storageUnavailable` — no signing/entitlements under `CODE_SIGNING_ALLOWED=NO`), unrelated to this change |
| `Scripts/validate_open_source.sh`, `scripts/verify_appstore.py --source`, `Scripts/verify_zoo_catalog.sh --appstore`, `scripts/verify_zoo_downloads.py` | passed |
| `verify_appstore.py --app … --team-id PUH4GMFV56 --distribution --expected-version 2.1.2 --expected-build 84 --expected-xcode-build 27A9275` | `App Store bundle checks passed (signed distribution)` |

Two test-harness defects were found and fixed while verifying: `ImageModelDownloadFlows` swiped on an offscreen chip (now drags the identified `models.capability` scroll view), and `testRedesignedLibraryFiltersAndStorage` assumed the Image filter kept the installed scope (now asserts the Discover switch and returns to On device). A stale `LegalDocuments.supportURL` host assertion (`ondevice.fun` → `mesut.uk`, from the Token rebrand) was corrected.

## Signing and toolchain

Xcode 27.1 (`27A9275`), not the `Scripts/build_appstore.sh` pinned `27A266a`, so the archive was invoked directly with the same flags as the shipped 2.1.1 (82) build: LFM3 experimental runtime (`ONDEVICE_LFM3_SWIFT_FLAG=LFM3_EXPERIMENTAL`, `build/LFM3Native`, 167 `lfm3` symbols in the binary), `ONDEVICE_APPSTORE=YES`, model policy `APP_STORE`, `ONDEVICE_RESEARCH_BUILD=NO`, single-file compilation with `-jobs 4`.

Export is **manual**: this machine has no Apple ID account in Xcode (`exportArchive No Accounts`), so `ExportOptions-manual.plist` maps the three bundle IDs to their installed App Store profiles (`9a276e93…` app, `09aedc83…` Downloads, `d8bb8251…` Share) and signs with `Apple Distribution: MESUT CAN YAGCI (PUH4GMFV56)` (`3DC82149…`), all profiles valid to 2027-10-01.

## What to Test

`testflight-notes-en-US.txt` is the en-US copy; `testflight-notes.json` holds all eleven locales, and the ASC read-back (`build/appstore/2.1.2-84/test-notes-final.json`) confirms notes on **ar-SA, de-DE, el, en-US, es-ES, hi, ja, pt-PT, ro, ru, tr**.

## Not done here

- App Store version-level **What's New** for 2.1.2 was not set; this run only covers TestFlight notes.
- No external beta-review submission, no tester group changes, no App Review submission.
- The App Store listing still shows 2.1.1 as the approved version.
