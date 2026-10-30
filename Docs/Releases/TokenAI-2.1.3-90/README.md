# Token: Local AI Studio 2.1.3 (90) — TestFlight

Phase 3 of `Docs/LFM3_OMNI_PLAN.md`: questions about videos with LFM3-Omni (frames and soundtrack), plus the text-only sampling fix found while testing. Uploaded 2026-10-31, **VALID**, internal beta via the "Test" group; nothing submitted for external beta or App Review.

- Build ID: `8d5ac065-c8ee-404f-b4eb-41c2c00af96f`
- IPA: 94,525,007 bytes, SHA-256 `ced77ef1e9192c447ba4619a3dc4488d2446a00215437127a57779ef4deb0cb4`
- Source: `7df0095 (c61b490 video in chat + 675543f bump + 7df0095 text-only fix)` on branch `lfm3-omni`, archived from a clean worktree

## Verification actually run

| Check | Result |
| --- | --- |
| Host tests, normal / LFM3 / Omni modes | 84/84 each, incl. `OmniVideoLayoutTests` |
| iOS builds: Omni (b11960), normal (b11558), rolled back (b11938) | all compile, no new warnings; b11960 without `LFM3_OMNI` is refused |
| Real model on a Mac vs b11960 `llama-mtmd-cli --video` on `tools/mtmd/test-3.mp4` | same 20 frames at 704×352, identical stamps and soundtrack slices, 2,651 vs 2,648 prompt tokens |
| A Lens-style question ("what is said?") without the text-only bias | stopped at `<|mixed_start|>`; with it, a full answer quoting the dialogue (first 90 archive discarded, rebuilt from 7df0095) |
| Archive (Xcode 27.1 `27A9275`) and `verify_appstore.py` 2.1.3 (90) | passed; same files as 89 |
| What to Test read-back | 11/11 locales match `testflight-notes.json` |

Not run: the feature on a physical iPhone.
