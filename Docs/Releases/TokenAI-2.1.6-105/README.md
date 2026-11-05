# Token: Local AI Studio 2.1.6 (105) — TestFlight only

Fixes voice chat failing with "Error reading 'config.json'" when the chat model is a
GGUF imported from Files (tester screenshot, 2026-11-05, an imported LFM3 1.7B Q6_K).
The chat model is resolved at launch, before the Files-import scan; the fallback guessed
MLX from the folder name `local_<name>`. Voice mode reused that guess. It now looks for a
GGUF in the folder first (`8c956cc`).

- First uploaded as 2.1.5 (105): rejected with ITMS 90186/90062 because 2.1.5 was already
  READY_FOR_SALE, which closes its TestFlight train (`upload-2.1.5-rejected.log`). Rebuilt
  as 2.1.6 (`d9ae0b5`).
- TestFlight: uploaded 2026-11-05, **VALID**, internal "Test" group, build ID
  `3650bf16-8b23-492b-a870-6b6ca1f2fd34`. What to Test in 11 locales (`testflight-notes.json`,
  read back identical in `asc-test-notes-readback.json`).
- IPA: 98,837,326 bytes, SHA-256 `9a2799ba166199215b7e1a5b8ae2d0c643017fccb2db6574412ae859aa541a0a`.
- Source: `d9ae0b5` on `lfm3-omni`, archived from the clean release worktree with the
  104 command. `verify_appstore.py --source` and `--distribution --expected-version 2.1.6
  --expected-build 105` passed; app and both extensions read 2.1.6 (105).
- Omni compile gate and `build-for-testing` passed. The new unit test runs only on an
  iPhone and has not run; the fix has not been tried on a device.
