# Token: Local AI Studio 2.1.6 (106) — attached to App Store version 2.1.6, not submitted

Answers the 1-star "Voice is broken" review (2026-11-06, iPhone 17, 3B/4B GGUF, live
2.1.5 (104)): voice stopped after a few turns, then the app crashed. No crash data was
available (ASC diagnostics empty for 104/100), so the causes come from reading the code.

Fixes in `478dffb` (on top of 105's imported-GGUF voice fix `8c956cc`):
- Apple voice lookup moved off the main thread (`SystemSpeechService.resolveVoice`); on
  iOS 27.2 the per-sentence `AVSpeechSynthesisVoice` lookup can block in TextToSpeech.
- 20 s deadline on the Apple speech render; a stalled render ends the reply's speech.
- Voice turns pass `onError`: a failed turn shows a toast instead of silence.
- Recognizer restarts back off (0.25 s → 2 s) when a request fails within 1 s; toast
  after 5 in a row (`SpeechDictationService.recognitionRetryDelay`, unit test added).
- Neural voices check `MemoryAdvisor.availableMemoryForModel` before loading next to the
  chat model and fall back to Apple Voice without overwriting the saved voice choice.
- Voice turns use `forceNoThinking: true`.

- TestFlight: uploaded 2026-11-08, **VALID**, build ID `59086453-7d80-4219-b71a-c1b097048fea`,
  internal "Test" group. What to Test = the version's What's New, in 11 locales.
- App Store version 2.1.6 `a4a2b748-8e12-4097-b113-62455de8ffc3` (PREPARE_FOR_SUBMISSION,
  manual release), build 106 attached. Text in `AppStoreMetadata/TokenAI-2.1.6`.
- IPA: 98,848,584 bytes, SHA-256 `697c2476553c5c55e5177cd5197b8fa16bc2c4ea7c2096946f65e5eea389622a`.
- Source: `badbd42` on `lfm3-omni`, archived from the clean release worktree with the 105
  command. `verify_appstore.py --source` and `--distribution --expected-version 2.1.6
  --expected-build 106` passed; app and both extensions read 2.1.6 (106).
- Omni compile gate and `build-for-testing` passed. Unit tests run only on an iPhone and
  have not run; nothing has been tried on a device.
