# Token: Local AI Studio 2.1.3 (89) — TestFlight

Phase 2 of `Docs/LFM3_OMNI_PLAN.md`: LFM3-Omni-2B as an optional image model on the b11960 runtime. Uploaded 2026-10-31, **VALID**, internal beta **IN_BETA_TESTING**; nothing submitted for external beta or App Review.

- Build ID: `50b7f4e2-e05d-448b-8500-d047178937a4`
- IPA: 94,443,677 bytes, SHA-256 `e5be367f7ca328557985664622c4f17d2f9adeeccc1ae434ce65628a4d2d5258`
- Source: `2a63eec` on branch `lfm3-omni`, archived from a clean worktree

## Verification actually run

| Check | Result |
| --- | --- |
| Host tests, normal and `--lfm3-experimental` | 80/80 each, incl. `test_omniIsBlockedUnlessTheRuntimeHasItsVideoAPI` |
| iOS build-for-testing against b11960 | succeeded, same warnings as 88 |
| Archive (Xcode 27.1 `27A9275`), `verify_appstore.py` 2.1.3 (89) | passed (signed distribution) |
| IPA contents vs 88 | same files plus `LICENSES/Llama-b11960-MIT.txt` and `LICENSES/Models/LiquidAI--LFM3-Omni-2B-GGUF/LICENSE` |
| What to Test read-back | 11/11 locales match |

Not run: downloading Omni and asking about images on a device.
