# Token: Local AI Studio 2.1.7 (111) — TestFlight only

Fixes from the 2026-11-14 code audit of 2.1.7 (110). Every finding came from reading the code; none was reproduced on a phone.
- `cdce95d`, Local API: the HTTP parser returned buffer indices where the server expected byte counts, so every request after the first on a kept-alive connection waited out the 30 s timeout and was dropped. Present since build 55.
- `cdce95d`, lifecycle and data:
  - Wipe All abandons every background download job and cancels its tasks before deleting.
  - The background-task expiration handler ends the task.
  - On background the chat screen stops a web lookup, document search or image preparation still in flight and keeps the prompt as a draft.
  - A conversation keeps its newest five unsent drafts.
- `cdce95d`, tools and runtime:
  - Web page fetch enforces the 2 MB cap while reading.
  - `describe()` resets the sampler between Lens captions (LFM3 vision penalty window).
  - The bare-JSON tool scanner finds a call that follows an unpaired quote in the prose.
- `cdce95d`, voice and Lens: a voice turn that exits before a reply starts is removed from the history; Lens Live does not start another cycle when Stop lands during the wait for the model.
- Bump: `2960bd0`.

- TestFlight: uploaded 2026-11-14, **VALID**, build ID `1170fc64-4fab-4c09-8590-1a9e32bb24e7`, internal "Test" group. What to Test is in en-US only (`testflight-notes-en-US.txt`).
- IPA: 99,612,854 bytes, SHA-256 `25a58d83129fe79e3139b38e3996c79d9d9a98aa6ff830c36f8c78f302703eaa`.
- Source: `2960bd0` on `lfm3-omni`, archived from the clean release worktree. `verify_appstore.py --source` and `--distribution --expected-version 2.1.7 --expected-build 111` passed, and `validate_localizations.py --app-bundle` confirmed the compiled strings (14 languages, 1,511 keys; no strings changed in this build).
- Checks before the upload: production `build-for-testing` with the Omni flags, `validate_open_source.sh`, host contract tests (86 of 86, including the new scanner test), and a host probe that runs the app's `HTTPRequest` parser through three requests on one connection (passes; the unpatched parser fails at request 2).
- Not run: the simulator UI suite, the OnDeviceUI package tests (package untouched) and the app unit tests, which need an iPhone. The new `LocalAPIServerTests` case is compiled only.
- Nothing has been tried on a device. The wipe, background, web-fetch, sampler, drafts, voice and Lens Live changes are compile-checked only.
- Audit leads left open because they need a phone to confirm: the voice playback meter tap keeping its format across an audio route change, a non-streaming API client disconnect not stopping generation, Lens/Omni captions ignoring critical thermal state mid-decode, a hung speech-engine load holding the microphone closed, no deadline on the Mac bridge inference stream, and DNS rebinding past the URL validator.
- The live App Store version is 2.1.6 (107). No App Store version 2.1.7 exists yet.
