# Token: Local AI Studio 2.1.3 (88) — TestFlight

Phase 1 of `Docs/LFM3_OMNI_PLAN.md`: the same app as 2.1.3 (87), archived against llama.cpp **b11960** (`build/LFM3OmniNative`) instead of b11938. Uploaded 2026-10-31, **VALID**, internal beta **IN_BETA_TESTING**; nothing submitted for external beta or App Review.

- Build ID: `34a7d044-3ea7-4bf4-b11d-6dc0f5d388b7`
- IPA: 94,434,393 bytes, SHA-256 `3a00044006555b53f93c8a8212ac444033416a222e7eec85d49e75f0feb11d07`
- Source: `e33d21b` on branch `lfm3-omni` (archived from a clean worktree, so uncommitted work in the main checkout is not in it)

## Verification actually run

| Check | Result |
| --- | --- |
| Host tests, normal and `--lfm3-experimental` | 79/79 each |
| iOS build-for-testing against b11960 | succeeded, same 110 warnings as b11938 |
| Archive, Xcode 27.1 (`27A9275`), LFM3 flags with `build/LFM3OmniNative` | succeeded; bundled `llama.framework` exports `mtmd_get_video_config` |
| `verify_appstore.py … --expected-version 2.1.3 --expected-build 88 --expected-xcode-build 27A9275` | passed (signed distribution) |
| IPA contents vs 87 | same 289 files; differences are the app and llama binaries, re-signed frameworks, and three license files whose line endings differ (identical text) |
| What to Test read-back | 11/11 locales match `testflight-notes.json` |

Not run: the Phase 0 device comparison with 87.
