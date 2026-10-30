# Token: Local AI Studio 2.1.3 (91) — TestFlight

Phase 4 of `Docs/LFM3_OMNI_PLAN.md`: a Lens Clip mode (6 s at 2 fps plus the microphone) answered by LFM3-Omni. Uploaded 2026-10-31, **VALID**, internal beta via the "Test" group; nothing submitted for external beta or App Review.

- Build ID: `5cb10ba8-1f9d-4e17-a9a7-b48654dbd5ba`
- IPA: 94,556,258 bytes, SHA-256 `e820b407c88cd635bdd9d9af0f9310eb4fe7e10a4b48c651ca1eff55ac87738d`
- Source: `da1739b (12c9b9d Lens clips + bump)` on branch `lfm3-omni`, archived from a clean worktree

## Verification actually run

| Check | Result |
| --- | --- |
| Host tests, normal / Omni modes | 84/84 each; localization check passes (new "Clip" strings in 6 languages) |
| iOS build against b11960 | compiles, no new warnings |
| Real model on a Mac, `OMNI_HARNESS_SOURCE=live` (frames at 2 fps plus a separate audio file) | 20 frames, 160,000 samples, full answer quoting the dialogue |
| Archive and `verify_appstore.py` 2.1.3 (91) | passed; same files as 90 |
| What to Test read-back | 11/11 locales match `testflight-notes.json` |

Not run: the feature on a physical iPhone.
