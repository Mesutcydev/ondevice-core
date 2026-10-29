# Token: Local AI Studio 2.1.2 (85) — TestFlight

Build **2.1.2 (85)** was uploaded to App Store Connect on 2026-10-29 and reported **VALID** with internal beta state **IN_BETA_TESTING** (auto-notify on; the internal "Test" group has access to all builds). External testing remains **READY_FOR_BETA_SUBMISSION**; nothing was submitted for beta review or App Review.

- TestFlight: <https://appstoreconnect.apple.com/apps/6774354746/testflight/ios>
- Build ID: `d5f30cff-3e4f-421a-8904-959480e88e71`
- IPA: 94,251,509 bytes, SHA-256 `7281c2b780cba0fe5b67e9ec36a989697fc4ffc9d6204f65c00d486be40e1920`
- Source: `9a0b34a` (LFM3 audit fixes) + `3a8ec93` (build bump)
- Receipt: [upload-receipt.json](upload-receipt.json)

## What is in the build

| Area | Change |
| --- | --- |
| LFM3 tools with GitHub | Only app tools get native schemas; repository tools use the GitHub catalog. The 22 repository schemas plus the GitHub contract overflowed the 4K window and the bridge cut the start of the system prompt. |
| LFM3 tool format | Schemas follow Liquid's `tool_to_json` layout and end the system turn. A call may follow answer text (kept visible); calls in Markdown code or followed by prose never run. |
| LFM3 file edits | `content`, `oldText` and `newText` keep exact whitespace, as in Liquid's parser. |
| LFM3 sampling | Without a saved per-model profile: temperature 0.1, top-k 50, repeat 1.1 (model card). Shown as "Model card defaults". |
| All GGUF models | Compaction reserves room for the system prompt; an over-long prompt keeps its first turn plus the newest whole turns. |

## Verification actually run

| Check | Result |
| --- | --- |
| `scripts/test_minicpm_v47.sh` and `--lfm3-experimental` | 79 passed each |
| iOS `build-for-testing` with the LFM3 runtime | succeeded |
| Archive, Xcode 27.1 (`27A9275`), same flags as 2.1.2 (84) incl. `ONDEVICE_LFM3_SWIFT_FLAG=LFM3_EXPERIMENTAL` | succeeded; 147 `lfm3` symbols |
| `verify_appstore.py --app … --team-id PUH4GMFV56 --distribution --expected-version 2.1.2 --expected-build 85 --expected-xcode-build 27A9275` | `App Store bundle checks passed (signed distribution)` |
| What to Test read-back ([asc-test-notes-readback.json](asc-test-notes-readback.json)) | all 11 locales match [testflight-notes.json](testflight-notes.json) exactly |

Not run: physical-iPhone checks of LFM3 tools, long GitHub conversations, or other GGUF models against this build; `QA/NativeUI` UI flows.

The first upload attempt stopped before uploading: the default Blitz `asc` config returned no beta groups ("beta group not found"). The retry used `ASC_CONFIG_PATH=~/.asc/config.json` with the same `cld1` key.
