# Token: Local AI Studio 2.1.4 (102) — TestFlight only

Fixes the empty Voices page ("Sesler · 0" even with voices installed). The
cause is in builds 100 and 101: since 100, Apple's voice list loads off the
main thread, and ODBridge cached the page's list per engine, so it kept the
empty list from before that load finished (`bfebdd1`). Otherwise the same as
101 (voice-models work, ONNX Runtime 1.30.0, whisper.cpp 1.9.5).

- TestFlight: uploaded 2026-11-01, **VALID**, internal "Test" group, build ID `81cdde0c-12e5-45c9-9d44-96ae467dc466`. What to Test is set in 11 locales (`testflight-notes.json`, read back in `asc-test-notes-readback.json`).
- Not attached to the 2.1.4 App Store version; App Review still has build 100, which has the empty Voices page.
- IPA: 98,803,780 bytes, SHA-256 `252335b85b5468d5e2bc36334d3decf92912edf121a9c4ebcfec5d2d43e6ae6c`.
- Source: `9000261` on `lfm3-omni`, archived from the clean release worktree with the 101 command (including `ONDEVICE_WHISPER_ROOT`). `verify_appstore.py --distribution --expected-version 2.1.4 --expected-build 102` passed.
- The app and tests (including the new SystemSpeechServiceTests) compile. Not yet run on an iPhone.
