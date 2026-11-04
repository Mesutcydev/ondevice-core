# Token: Local AI Studio 2.1.5 (103) — TestFlight only

Adds Lens Live for LFM3 Omni: Omni watches the camera in 3 s windows and writes
a short comment for each, newest first, until Stop, leaving Lens, or the device
getting too warm (`2245107`). The same commit makes "Speak in Lens" work (no
code called the narrator), labels Clip's shutter "Record", gives Clip and Live
real progress stages, resets the result when switching to Clip or Live, and
uses the mode menu when six segments would truncate a title (German).

- Marketing version 2.1.5 because 2.1.4 went READY_FOR_SALE, which closes its TestFlight train.
- TestFlight: uploaded 2026-11-04, **VALID**, internal "Test" group, build ID `f89cf799-b429-49fd-90a6-35127a59130c`. What to Test is set in 11 locales (`testflight-notes.json`, read back identical in `asc-test-notes-readback.json`).
- IPA: 98,836,505 bytes, SHA-256 `c6ae0c313b5de3a66d3c3d6acb7b47058046920297f272e15e36b6dc4d3605a7`.
- Source: `bfec1c8` on `lfm3-omni`, archived from the clean release worktree with the 102 command (Omni flags, `ONDEVICE_WHISPER_ROOT`). `verify_appstore.py --source` and `--distribution --expected-version 2.1.5 --expected-build 103` passed.
- Checks before upload: Omni compile gate, OnDeviceUI package tests (17), native UI host contracts (89), localization and repository validators; Lens screenshots in the review host in English, Spanish (six segments fit) and German (menu).
- Not checked: Live on an iPhone with the real model (latency per comment, heat over a few minutes). Device installs other than TestFlight are still refused for this team.
