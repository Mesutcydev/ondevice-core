# Token: Local AI Studio 2.1.3 (94) — TestFlight

A chat no longer loads a model that is not on the device. On the test phone a new chat used the never-downloaded default (Qwen3-4B 2507) and fetched it from the Hub inside the load, showing only "Preparing model". MLX loads now refuse missing weights like Core AI, Edge0 and GGUF loads already did, and the chat shows the reason with the model picker. Uploaded 2026-10-31, **VALID**, internal beta via the "Test" group; nothing submitted for external beta or App Review.

- Build ID: `33191634-9d03-437e-af6d-08036e7bb349`
- IPA: 94,622,865 bytes, SHA-256 `b409c21ebd0852e558696cd6499695f67af9f756c1d0c9799e17ad5a6b5e3e16`
- Source: `14f3079` on branch `lfm3-omni`, archived from a clean worktree

## Verification actually run

| Check | Result |
| --- | --- |
| Host tests, normal / LFM3 / Omni modes | 85/85 each |
| iOS builds: Omni (b11960), normal (b11558), rolled back (b11938) | all compile, no new warnings in the changed files |
| Archive (Xcode 27.1 `27A9275`), `verify_appstore.py` 2.1.3 (94) | passed; same files as 93 |
| What to Test read-back | 11/11 locales match `testflight-notes.json` |

Not run: anything on a physical iPhone (Apple refuses development installs; see `Docs/LFM3_OMNI_PLAN.md`). No automated test covers the refusal, since the chat service's tests only run on a device.
