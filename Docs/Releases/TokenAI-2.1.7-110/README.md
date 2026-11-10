# Token: Local AI Studio 2.1.7 (110) — TestFlight only

Fixes from the 2026-11-10 audit of 2.1.7 (109), plus more translations:
- `8a8d1c0`, model management:
  - Storage Cleanup starts with "Partial downloads" unticked (clearing resume data restarts paused downloads), waits for removals and reports what is actually gone.
  - ODBridge re-reads download receipts only when a download's state or file changes or an image model is installed or deleted, not on progress ticks.
  - Cancelling an image download while that model generates explains why nothing happens.
  - The token sheet retries a gated download only after a different token was saved.
- `8a8d1c0`, layout: the drawer's destination grid uses two columns when a language's labels would not fit three, so Russian, Greek, Spanish and similar names are not cut off. English is unchanged.
- `8a8d1c0`, localization:
  - About 330 new catalog strings in all 14 languages: Storage Cleanup, Hugging Face search and token, Core AI packs, voice and assistant pickers, Local API, Knowledge Base, User Guide, the coding workspace, web settings and labels passed to shared components.
  - KoduComponents look their text up in the catalog with the in-app language (`KLocalizedLabel`); a label with no entry is shown unchanged.
  - Navigation paths in translated sentences use the translated menu names.
  - Still English: Diagnostics, the voice validation tools, parts of the GitHub workspace and toast text.
- Bump: `daf193f`.

- TestFlight: uploaded 2026-11-10, **VALID**, build ID `e6904c66-6225-49c9-ac15-7b9c604e1f4b`, internal "Test" group. What to Test is in en-US only (`testflight-notes-en-US.txt`).
- IPA: 99,597,081 bytes, SHA-256 `1c31aa9bde7931259bbf2f6921d78547877316f434e596598b3b6a756dc08e27`.
- Source: `daf193f` on `lfm3-omni`, archived from the clean release worktree. `verify_appstore.py --source` and `--distribution --expected-version 2.1.7 --expected-build 110` passed, and `validate_localizations.py --app-bundle` confirmed the compiled strings in the app, package and both extensions (14 languages, 1,511 keys).
- Checks before the upload: production `build-for-testing`, host policy scripts, `validate_open_source.sh`, OnDeviceUI package tests (17 of 17), host contract tests (89 of 89).
- Simulator UI suite (127 tests): the 7 failures that also fail on the untouched `1bf3b28` still fail (two ClassifierWorkbench, two CodingWorkspace, MiniCPM 35B row, home search/pin, Files folder picker). `APIServerWorkspaceTests.testLiveParserMovesWhileGenerating` fails too, but it fails identically on `1bf3b28` and `0b625e9` on the same simulator, so it is not caused by these changes (cause not found; it checks that an animation changes between screenshots). Tests that typed text lost trailing characters (the known typing flake) and passed on retry. A failing LocalizationFlows test leaves the app in another language, so the classes were rerun from a clean install.
- The translations were written by Claude and have not been reviewed by native speakers.
- Nothing has been tried on a device: the new cleanup waiting, the receipt re-reads, the image-cancel message and the shared-component translations are compile-checked and exercised only in the simulator review host (which does not include the app-target screens).
- The live App Store version is 2.1.6 (107). No App Store version 2.1.7 exists yet.
