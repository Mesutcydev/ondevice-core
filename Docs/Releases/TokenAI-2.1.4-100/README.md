# Token: Local AI Studio 2.1.4 (100) — submitted for App Review

Fixes the Voice settings freeze. On iOS 27.2, `AVSpeechSynthesisVoice.speechVoices()` blocks the main thread in a TextToSpeech forced-sync. The voice picker read it from a binding getter, so opening Voice settings or tapping the System engine hung until the watchdog killed the app (`0x8BADF00D` in the phone's Token AI 2.1.4 (99) crash report, 2026-11-01 20:03). Voices are now snapshotted off the main thread (`6be029f`).

- TestFlight: uploaded 2026-11-01, **VALID**, internal "Test" group, build ID `e5e8b763-c4e0-4c24-a414-5afc65ef3e74`. What to Test is set in 11 locales (`testflight-notes.json`, read back in `asc-test-notes-readback.json`).
- App Store version 2.1.4 `c0302f96-3f59-458e-91c6-4673df0ef6a9`: build 99 replaced by build 100 (`asc-attach-build.json`). On the user's request it was submitted: review submission `2146c2c6-40be-41f8-86f0-421061fd09de`, **WAITING_FOR_REVIEW**, release type manual. The header-video submission `6936b0f3` was left alone.
- What's New: the image-gate bullet from build 99 plus a Voice settings bullet, all 11 locales (`whats-new.json`). The promotional text is unchanged (the live 2.1.3 text), re-sent with What's New. Both read back in `asc-localizations-readback.json`.
- `asc validate`: 0 errors, 1 warning (`APP_IPHONE_DUO` display type unknown to the tool, as before).
- IPA: 94,654,581 bytes, SHA-256 `53ca384a8099dffa130d89255ca7dd3fa0682c2b0deac89a7f6366cc3b246c10`.
- Source: `988b4f1` on `lfm3-omni` (the build bump on top of `6be029f`), archived from the clean release worktree with the 99 command. `verify_appstore.py --distribution --expected-version 2.1.4 --expected-build 100` passed.

## Verification

The compile gate passed on `ondevice-max`, and the archive contains `SystemSpeechService.refreshVoices`. The fix has not been run on a physical iPhone; the TestFlight build is the first device check.
