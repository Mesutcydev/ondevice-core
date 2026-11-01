# Token: Local AI Studio 2.1.4 (101) — TestFlight only

Test build of the voice-models work. App Review keeps build 100 (submission
`2146c2c6`); this build is not attached to the 2.1.4 App Store version.

- TestFlight: uploaded 2026-11-01, **VALID**, internal "Test" group, build ID `d74aabea-5465-4fc6-8631-94b10e968a36`. What to Test is set in 11 locales (`testflight-notes.json`).
- IPA: 98,806,492 bytes, SHA-256 `a7294d7fdcb8251258d6c26458d21129065f9032040408cd02f5e08badf0e91c`.
- Source: `65a1cbb` on `lfm3-omni` (fast-forwarded from `voice-models`), archived from the clean release worktree with the build 100 command plus `ONDEVICE_WHISPER_ROOT=$PWD/build/WhisperNative`. That folder links to the shared `OnDeviceMax/build/WhisperNative`, made by `scripts/bootstrap_whisper_runtime.py`.
- `verify_appstore.py --distribution --expected-version 2.1.4 --expected-build 101` passed. The bundled AuditedModelRevisions.json has the Supertonic 3, Paradee-8M, Parakeet v3 and Nemotron 3.5 ASR pins, so their downloads appear in the public build.

## What changed since 100

- New voices: Supertonic 3 (31 languages) and Paradee-8M (English). KittenTTS and Kokoro now pronounce "er" sounds.
- New hold-to-talk speech-to-text choices: Apple SpeechAnalyzer, Parakeet TDT v3, Nemotron 3.5 ASR, and Whisper tiny/small/large-v3-turbo.
- Runtimes: ONNX Runtime 1.23.0 → 1.30.0, and whisper.cpp 1.8.4 → 1.9.5 (in this archive only, via the setting).

## Verification

Every engine was checked on a Mac against the app's own source files and its ONNX Runtime (`scripts/onnx-harness`); see the commit messages on `lfm3-omni` for numbers. **Nothing has been run on an iPhone yet.** This build is the first device check: speech, memory, thermals, Metal (whisper 1.9.5) and Core ML. To return to whisper.cpp 1.8.4, archive without `ONDEVICE_WHISPER_ROOT`.
