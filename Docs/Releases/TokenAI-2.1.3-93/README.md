# Token: Local AI Studio 2.1.3 (93) — TestFlight

Fixes LFM3 Omni 2B missing from Models in 89–92: public builds drop downloads whose repo is not in `AuditedModelRevisions.json`, and Omni was not there. Uploaded 2026-10-31, **VALID**, internal beta via the "Test" group; nothing submitted for external beta or App Review.

- Build ID: `c79fedc7-b8ad-4a64-824d-2d6dea77ef96`
- IPA: 94,624,239 bytes, SHA-256 `bfc28b55c37b7149fba2086e840295ddbdcb1dc8953c40b87a65cd9e4789a462`
- Source: `96b91a2` on branch `lfm3-omni`, archived from a clean worktree

## Verification actually run

| Check | Result |
| --- | --- |
| `verify_appstore.py --source` | passes; fails when the Omni pin is removed |
| Archive (Xcode 27.1 `27A9275`), `verify_appstore.py` 2.1.3 (93) | passed; same files as 92; the bundled inventory lists `LiquidAI/LFM3-Omni-2B-GGUF` |
| What to Test read-back | 11/11 locales match `testflight-notes.json` |

Not run: anything on a physical iPhone. Development and Ad Hoc installs are refused by Apple's online authorization (`REJECT_PROFILE`), so device checks go through this TestFlight build.
