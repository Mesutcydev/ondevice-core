# Token: Local AI Studio 2.1.3 (92) — TestFlight

Phase 5 of `Docs/LFM3_OMNI_PLAN.md`: LFM3-Omni speech-to-text, its own voice, and voice chat on one resident model, plus the fixes from an xhigh code review of the whole `lfm3-omni` branch. Uploaded 2026-10-31, **VALID**, internal beta via the "Test" group; nothing submitted for external beta or App Review.

- Build ID: `233da3e6-56f6-404a-91b5-902c79d86129`
- IPA: 94,624,325 bytes, SHA-256 `f3e5e2b06ce9e99b695b721b84f6f88e85a4ed46bea9e1e2cccd535469266681`
- Source: `2e336b8` on branch `lfm3-omni`, archived from a clean worktree (a first 92 archive from `737a69d` was discarded before upload)

## Verification actually run

| Check | Result |
| --- | --- |
| Host tests, normal / LFM3 / Omni modes | 85/85 each, incl. speech-prompt and region-code tests |
| iOS builds: Omni (b11960), normal (b11558), rolled back (b11938) | all compile with no new warnings; b11960 without `LFM3_OMNI` is refused |
| Real model on a Mac: video vs `llama-mtmd-cli` | still 2,651 vs 2,648 tokens with identical frames, stamps and audio slices |
| Real model on a Mac: transcription of `tools/mtmd/test-2.mp3` | accurate |
| Real model on a Mac: speech, English | 5.9 s of 24 kHz audio in 2.0 s; transcribed back to the input sentence |
| Real model on a Mac: speech, Turkish | 5.6 s in 1.6 s; Turkish words transcribe back correctly, English brand names do not |
| Archive (Xcode 27.1 `27A9275`), `verify_appstore.py` 2.1.3 (92) | passed; same files as 91 |
| What to Test read-back | 11/11 locales match `testflight-notes.json` |

Audit findings fixed in this build and two kept as is are listed in `Docs/LFM3_OMNI_PLAN.md`. Not run: any of it on a physical iPhone (dictation, the Omni voice, voice chat, memory and thermal behaviour).
