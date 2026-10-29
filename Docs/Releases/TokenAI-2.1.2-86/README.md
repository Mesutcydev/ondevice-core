# Token: Local AI Studio 2.1.2 (86) — TestFlight

Build **2.1.2 (86)** was uploaded to App Store Connect on 2026-10-29 and reported **VALID** with internal beta state **IN_BETA_TESTING** (about five minutes after processing; auto-notify on, the internal "Test" group has access to all builds). External testing remains **READY_FOR_BETA_SUBMISSION**; nothing was submitted for beta review or App Review.

- TestFlight: <https://appstoreconnect.apple.com/apps/6774354746/testflight/ios>
- Build ID: `95c89865-3e5f-4fff-9742-5d849653c30e`
- IPA: 94,298,834 bytes, SHA-256 `18f6b6114ce0daaf82b6c5f15049aed124a23c1b3ad03ade9f8e5c4f19eefe22`
- Source: `f47a0ca` (Code tab repository picker) + `d80da52` (build bump), on top of build 85's LFM3 fixes
- Receipt: [upload-receipt.json](upload-receipt.json)

## What is in the build

| Area | Change |
| --- | --- |
| Code tab repository picker | Presented inside a navigation stack with Done. Before, the Code tab showed it bare, so "GitHub settings", "Enter a repository" and every repository row were inert. |
| Picker design | GitHub off or not connected: an empty state with one "Open GitHub settings" action. Connected: an account card that also opens settings, a current-repository card with its actions, and flat repository rows on the page background. |
| Branch / Add repository | Same page style, section headers and error card. |

## Verification actually run

| Check | Result |
| --- | --- |
| `QA/NativeUI` `GitHubFlows` on iOS 27.0 (`EFD851BF`), incl. new `testCodeTabRepositoryPickerOpensSettingsAndBranches` | 5 passed |
| iOS `build-for-testing` with the LFM3 runtime | succeeded |
| Archive, Xcode 27.1 (`27A9275`), same flags as 2.1.2 (85) incl. `ONDEVICE_LFM3_SWIFT_FLAG=LFM3_EXPERIMENTAL` | succeeded; 147 `lfm3` symbols |
| `verify_appstore.py --app … --team-id PUH4GMFV56 --distribution --expected-version 2.1.2 --expected-build 86 --expected-xcode-build 27A9275` | `App Store bundle checks passed (signed distribution)` |
| What to Test read-back ([asc-test-notes-readback.json](asc-test-notes-readback.json)) | all 11 locales match [testflight-notes.json](testflight-notes.json) exactly |

Not run: physical-iPhone checks against this build, or light-mode screenshots (QA flows run in dark mode). Upload used `ASC_CONFIG_PATH=~/.asc/config.json`; the default Blitz config returned no beta groups for build 85.
