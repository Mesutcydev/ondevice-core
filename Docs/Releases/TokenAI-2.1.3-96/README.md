# Token: Local AI Studio 2.1.3 (96) — TestFlight

Images the assistant generates appear in the chat, with Image studio's live progress while they are made, and a declined tool ends tool use for that reply. Uploaded 2026-10-31, **VALID**, internal beta via the "Test" group; nothing submitted for external beta or App Review.

- Build ID: `50c32538-7940-4178-8e68-b2001cddf6ab`
- IPA: 94,627,549 bytes, SHA-256 `3e6a4168a9812263c7151955329abbddfcd35bb0465facef87c4bfe820a5fb57`
- Source: `e921b14` on branch `lfm3-omni` (fixes in `39b304c`), archived from a clean worktree

## What changed

- The chat's assistant message only drew text, so the image message added after `generate_image` showed as an empty row. It now draws the image.
- The image waited at most 3 minutes and only while the reply's request scope held, so a slow SDXL Turbo load or a new message dropped it. It now waits for the generation to end and lands in the conversation that asked for it.
- After the user declines or cancels a tool, the rest of that turn runs without tools.

## Verification actually run

| Check | Result |
| --- | --- |
| Mac, LFM3-1.7B-Uncensored-AD-Q6_K, llama.cpp b11960, temp 0.1 / top-k 50 / repeat 1.1, the app's prompt for "Write me a animated website bacground html code" | `generate_image` in 2/3 runs (unchanged; prompt rewording made it 3/3, so it was not shipped) |
| Same, follow-up after a declined `generate_image` | with tools: `web_search` 3/3; without tools (this fix): HTML answer 3/3 |
| QA/NativeUI HostContracts on an iOS 27 simulator | 46/46, including the new decline test |
| iOS build, Omni (b11960) | compiles, no new warnings in the changed files |
| Archive (Xcode 27.1 `27A9275`), `verify_appstore.py` 2.1.3 (96) | passed; same files as 95 |
| What to Test read-back | see `asc-test-notes-readback.json` |

Not run: the image and decline flows on a physical iPhone; the normal (b11558) and rolled-back (b11938) compile gates, which stopped when the disk filled (the changed code has no build-flag branches).
