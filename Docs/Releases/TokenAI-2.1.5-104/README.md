# Token: Local AI Studio 2.1.5 (104) — TestFlight only

Fixes Live comments being cut off after three lines (tester screenshot, 2026-11-04):
the Lens panel showed the first lines of every comment joined together. In Live it
now shows the whole newest comment in 4 to 8 lines; the result sheet keeps all of
them (`0a1ccaa`). Otherwise the same as 103.

- TestFlight: uploaded 2026-11-04, **VALID**, internal "Test" group, build ID `7b89875e-1bc4-4a77-91ce-faac63a2508b`. What to Test in 11 locales: the fix line, then the 103 Live notes (`testflight-notes.json`, read back identical in `asc-test-notes-readback.json`).
- IPA: 98,836,611 bytes, SHA-256 `4b01487d41c08239f275e21f9d9cf31b73a2ccd9a9bea770608f410fc24a8b7b`.
- Source: `d7ab748` on `lfm3-omni`, archived from the clean release worktree with the 103 command. `verify_appstore.py --source` and `--distribution --expected-version 2.1.5 --expected-build 104` passed.
- Checked in the review host with a five-line Turkish-UI comment. Not changed yet: the model row still says "Vision model required" during Clip/Live, and Live comments come back in English whatever the app language.
