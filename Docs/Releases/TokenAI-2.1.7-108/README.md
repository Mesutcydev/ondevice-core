# Token: Local AI Studio 2.1.7 (108) — TestFlight only

Voice audit on top of the live 2.1.6 (107), partly from the CodeLens voice audit session:
- `ea61668`, functioning:
  - Stray resumption recommendations no longer close the voice screen.
  - Interrupted shows Resume.
  - A neural voice that isn't ready falls back to Apple Voice instead of blocking voice mode or a silent reply.
  - 15 s no-audio watchdog.
  - Waits out output latency before reopening the mic.
  - Voice ignores the global JSON mode.
  - The Kitten variant is saved.
  - STT rows select the hold-to-talk provider.
  - Download hashing runs in per-chunk autorelease pools.
  - Echo-cancellation copy, and the model-loading notice on the voice screen.
- `5b82657`: the Voice engines sheet is redesigned as cards. Unavailable families are collapsed, and the details sheet is restyled.

- First uploaded as 2.1.6 (108): rejected with ITMS 90062/90186, because 2.1.6 (107) had been released (`upload-2.1.6-rejected.log`). Moved to 2.1.7 in `d7bf760`.
- TestFlight: uploaded 2026-11-09, **VALID**, build ID `94f62680-e6dd-4f49-a0b6-74c9a63d1552`, internal "Test" group. What to Test is in en-US only (`testflight-notes-en-US.txt`).
- IPA: 98,972,045 bytes, SHA-256 `63f52b2102393e4b084b60f13b197c67a03d96aa59e8bda5a2a21cda342c1f12`.
- Source: `d7bf760` on `lfm3-omni`, archived from the clean release worktree. `verify_appstore.py --source` and `--distribution --expected-version 2.1.7 --expected-build 108` both passed. The app and both extensions read 2.1.7 (108).
- `build-for-testing` and `validate_localizations.py` passed. The unit tests run only on an iPhone and have not run. Nothing has been tried on a device. No App Store version 2.1.7 exists yet.
