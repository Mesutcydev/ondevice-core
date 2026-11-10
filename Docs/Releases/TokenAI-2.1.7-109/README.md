# Token: Local AI Studio 2.1.7 (109) — TestFlight only

Model-management audit fixes and eight complete translations on top of 2.1.7 (108):
- `84801b2`, model management:
  - Storage Cleanup protects image models that are still downloading, starts with every model kept, sizes rows from measured bytes, and lists image, Core AI and classifier models.
  - Image-model downloads can be cancelled from Models, Downloads and Image studio.
  - Deleting the loaded GGUF Lens model unloads llama.cpp.
  - ODBridge no longer reads download receipts from disk for every streamed token.
  - A gated-repository failure opens the token sheet from Resume, then retries.
  - Hub downloads show bytes transferred and an estimate of time left.
  - Search keeps "Search Hugging Face" while typing; Import shows a busy state.
- `84801b2`, localization:
  - French, Portuguese, Italian, Greek, Romanian, Russian, Simplified Chinese and Korean go from 303 to 1,166 catalog strings each, plus the six permission prompts.
  - 176 mistranslated Greek and Romanian strings are corrected.
  - `validate_localizations.py` now requires all fourteen languages.
- `84801b2`, housekeeping: the unused `ModelsManagerView` and `FixRepoSheet` are removed.

- TestFlight: uploaded 2026-11-10, **VALID**, build ID `eb66fe23-0c11-44e6-961b-6a6cf64aa777`, internal "Test" group. What to Test is in en-US only (`testflight-notes-en-US.txt`).
- IPA: 98,831,931 bytes, SHA-256 `2435e5c4585561ff996ffec8fddbc1c72af35a4cb241ab039d695e8c6aef6241`.
- Source: `154e0f1` on `lfm3-omni`, archived from the clean release worktree. `verify_appstore.py --source` and `--distribution --expected-version 2.1.7 --expected-build 109` both passed. The app and both extensions read 2.1.7 (109).
- `build-for-testing`, the host policy scripts, `validate_open_source.sh` and `validate_localizations.py --app-bundle` (compiled strings in the app, package and both extensions, fourteen languages) passed.
- The new translations were written by Claude and have not been reviewed by native speakers. French Models, Russian Settings and the Greek sidebar were looked at in the simulator review host.
- The unit tests run only on an iPhone and have not run. Nothing has been tried on a device: image-download cancel, the token sheet retry, the cleanup rows for image, Core AI and classifier models, the GGUF Lens unload and the time-left label are compile-checked only.
- The live App Store version is 2.1.6 (107). No App Store version 2.1.7 exists yet.
