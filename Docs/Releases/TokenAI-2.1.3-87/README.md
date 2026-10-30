# Token: Local AI Studio 2.1.3 (87) — TestFlight

Build **2.1.3 (87)** was uploaded to App Store Connect on 2026-10-31 and reported **VALID** with internal beta state **IN_BETA_TESTING** (auto-notify on, the internal "Test" group has access to all builds). External testing remains **READY_FOR_BETA_SUBMISSION**; nothing was submitted for beta review or App Review.

- TestFlight: <https://appstoreconnect.apple.com/apps/6774354746/testflight/ios>
- Build ID: `ac794e7c-b437-4bfd-9bf5-1d57b202ff31`
- IPA: 94,301,669 bytes, SHA-256 `e35673bc8a3283410347de61d603a49723d5254576bd4af6b52a7de091be4175`
- Receipt: [upload-receipt.json](upload-receipt.json)

## Why 2.1.3 and not 2.1.2

The first upload was built as 2.1.2 (87). Apple rejected it with **90186** and **90062**: App Store version 2.1.2 is now READY_FOR_SALE, which closes the 2.1.2 TestFlight train. `MARKETING_VERSION` and every `CFBundleShortVersionString` (`project.yml`, `IOSLocalLLM/Info.plist`, `DownloadActivityExtension/Info.plist`, `IOSLocalLLMShareExtension/Info.plist`, the pbxproj) moved to **2.1.3**; the build number stays **87**.

## What is in the build

| Area | Change |
| --- | --- |
| PDF summaries on small-context models | `FileAttachmentService.selectedPDFPageText` used to fall back to pages 1–2 when the question matched no page ("Summarize document for me" against a Turkish PDF). LFM3 then summarized only the cover and introduction and asked whether to read the rest. Summary requests ("summar", "overview", "özet") and questions with no page match now get an equal share of the prompt budget for every page (evenly spaced pages when the budget is too small), with whitespace collapsed. The file is labelled "excerpts across all N pages". Targeted questions still pick the best-matching pages. CodeLens summarized correctly because it fed the full text. |

## Verification actually run

| Check | Result |
| --- | --- |
| Host compile of `FileAttachmentService.swift` with an assertion script: 20-page summary covers pages 1–20 in 4,043 of 4,096 bytes; 80 pages in 2,000 bytes stay in budget; lunar-permit targeted query still picks page 27 | passed |
| New `PageAwarePDFTests.testSummaryQueryCoversWholeDocument` | compiled (iOS `build-for-testing` with the LFM3 runtime); not run, unit tests need a device |
| Archive, Xcode 27.1 (`27A9275`), same flags as 2.1.2 (86) incl. `ONDEVICE_LFM3_SWIFT_FLAG=LFM3_EXPERIMENTAL` | succeeded; 147 `lfm3` symbols; app and both extensions report 2.1.3 |
| `verify_appstore.py --app … --team-id PUH4GMFV56 --distribution --expected-version 2.1.3 --expected-build 87 --expected-xcode-build 27A9275` | `App Store bundle checks passed (signed distribution)` |
| What to Test read-back ([asc-test-notes-readback.json](asc-test-notes-readback.json)) | all 11 locales match [testflight-notes.json](testflight-notes.json) exactly |

Not run: the PDF summary on a physical iPhone. A development-signed install on the tester's iPhone was refused with 0xe8008018, which is why this went through TestFlight.
