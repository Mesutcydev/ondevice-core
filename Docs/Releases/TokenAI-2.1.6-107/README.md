# Token: Local AI Studio 2.1.6 (107) — replaces 106 on App Store version 2.1.6, not submitted

Builds on 106 (`478dffb`) with the voice findings a sibling CodeLens session found for the
same 1-star review, ported in `bb31b89`:
- Playback queue released when the engine stops or the playhead stalls for 3 s
  (`AudioPlaybackService.waitUntilQueueDrained`, `.AVAudioEngineConfigurationChange`).
  Streamed TTS goes through `schedule()`, which had no watchdog.
- Dead-mic watchdog in the VAD loop (engine stopped while listening → rebuild, 1/s);
  one-shot Test audio / Replay sets `.speaking` so it doesn't fire under them.
- `suspendForBackground()` from `LifecycleController.onBackground`, before generation is
  cancelled; "Try again" continues with the same history.
- Voice replies capped at min(setting, 512) tokens.
- Only the selected neural voice stays loaded (Omni excluded).
- `sanitizedHistory`: empty assistant turns dropped, back-to-back user turns merged.
- One 600 ms mic retry on start; transcript cleared on a call interruption; "Match chat"
  restores the chat model.
Already true here, not ported: loads never download (CodeLens #7), operation/turn tokens
(#8, #10), downloaded-only voice model picker (#13).

- TestFlight: uploaded 2026-11-08, **VALID**, build ID `2b71d58c-7f0c-4d8b-8c88-16287296dfea`,
  internal "Test" group, What to Test in 11 locales.
- App Store version 2.1.6 `a4a2b748…` now has build 107 attached (read back). What's New
  extended for 107 in 11 locales and read back (`AppStoreMetadata/TokenAI-2.1.6`).
- IPA: 98,865,454 bytes, SHA-256 `2ef6835feb137f9f78461afdc0637f09f7fe21cf80f608a6bd21d239d7f62a1d`.
- Source: `39bc944` on `lfm3-omni`, archived from the clean release worktree with the 106
  command. `verify_appstore.py --source` and `--distribution --expected-version 2.1.6
  --expected-build 107` passed; app and both extensions read 2.1.6 (107).
- Omni `build-for-testing` passed; `validate_localizations.py` passed. Unit tests run only
  on an iPhone and have not run; nothing has been tried on a device.
