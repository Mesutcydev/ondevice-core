# Token: Local AI Studio 2.1.4 (99) — App Store candidate, not submitted

The image-gate fix from 2.1.3 (98), shipped as a new version. 2.1.3 went live with build 97, and its version train is closed, so 98 can't be attached to it.

- TestFlight: uploaded 2026-10-31, **VALID**, internal "Test" group, build ID `343796cb-ac5e-45c7-b926-eafbf0ec1351`. What to Test is set in 11 locales and read back (`asc-test-notes-readback.json`).
- App Store version 2.1.4 `c0302f96-3f59-458e-91c6-4673df0ef6a9`: `PREPARE_FOR_SUBMISSION`, release type manual, build 99 attached. **Not submitted** (the user checks first).
- IPA: 94,635,824 bytes, SHA-256 `d8b727f08851b2eea26cbb5ef9ef5c52e643461ecbedb8a6997f14fc6acbd4cc`
- Source: `1248c0c` on branch `lfm3-omni` (the 2.1.4 (99) bump on top of the fix in `ddc2713`), archived from the clean release worktree with the 98 command.

## Metadata

- What's New: `whats-new.json`, 11 locales, one bullet about the image fix; read back in `asc-localizations-readback.json`.
- Description, keywords, URLs and promotional text were copied from 2.1.3 (`asc versions create --copy-metadata-from 2.1.3 --exclude-fields whatsNew`). The promotional text is the live 2.1.3 text and is unchanged.
- Screenshots, iPhone Duo screenshots, the app preview, the search asset and the product-page header came across from 2.1.3. The en-US header is still the clipped full-bleed video `aa000019…8126` (placement `cd000019-3c87-833a-8f2a-30cd5d36bfaa`). The safe-layout video is still in review (submission `6936b0f3`).
- `asc validate`: 0 errors, 1 warning (`APP_IPHONE_DUO` display type unknown to the tool, as for 2.1.3).

## Verification

Same code as 2.1.3 (98); see `../TokenAI-2.1.3-98/README.md` for the intent-check cases and the Mac replay. `verify_appstore.py --distribution --expected-version 2.1.4 --expected-build 99` passed. The bundle file list matches 98 apart from symbol UUIDs. The flow has not been run on a physical iPhone.
