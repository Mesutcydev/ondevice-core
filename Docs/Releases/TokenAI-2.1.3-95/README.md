# Token: Local AI Studio 2.1.3 (95) — TestFlight

PDF summaries cover the whole document. The fix (`fd9c2ba`: GGUF input budget reserves at most half the 4K window; the PDF overview drops "Page N:" headings and passes short pages' share on) was only on `ondevice-max` and missed 87–94; it is cherry-picked as `5e4806f`. Uploaded 2026-10-31, **VALID**, internal beta via the "Test" group; nothing submitted for external beta or App Review.

- Build ID: `84c506a3-835d-42c3-a242-784c215e4d83`
- IPA: 94,623,511 bytes, SHA-256 `736f88399946908d32fc83301773bec83373905c012f0722a2b7b5263f4f9b87`
- Source: `ab4ba44` on branch `lfm3-omni`, archived from a clean worktree

## Verification actually run

| Check | Result |
| --- | --- |
| Mac, app's `FileAttachmentService` on the tester's 12-page PDF (9.9 KB of text) | sends 3,356 bytes from every page; whole prompt 1,546 tokens (limit 2,048) |
| Mac, LFM3-1.7B-Uncensored-AD-Q6_K, llama.cpp b11960, temp 0.1 / top-k 50 / repeat 1.1 | whole-document summary for "Summarize document for me" and "Bu belgeyi özetle"; small slips ("Sweden", oat porridge as "yeast flour") |
| Host tests, normal / LFM3 / Omni modes | 85/85 each |
| iOS builds: Omni (b11960), normal (b11558), rolled back (b11938) | all compile, no new warnings in the changed files |
| Archive (Xcode 27.1 `27A9275`), `verify_appstore.py` 2.1.3 (95) | passed; same files as 94 |
| What to Test read-back | 11/11 locales match `testflight-notes.json` |

Not run: the PDF on a physical iPhone.
