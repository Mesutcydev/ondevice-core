# Token: Local AI Studio 2.1.3 (97) — App Store candidate

After the assistant generates an image, the chat model reloads by itself, and the next request no longer repeats the image. Uploaded 2026-10-31, **VALID**, internal beta via the "Test" group. The 2.1.3 submission with build 96 was cancelled, and build 97 is attached to version 2.1.3 (`PREPARE_FOR_SUBMISSION`). **Not submitted for App Review**; the user resubmits after checking.

- Build ID: `82d9f3ff-bf6e-4e6e-942a-745bb1f53013`
- IPA: 94,630,826 bytes, SHA-256 `79799b66a47c0de2492f6ac1b3cb9a0699a7116e7f1c3b64cf7809faeff5fc23`
- Source: `1d458f1` on branch `lfm3-omni` (fixes in `818da92` and `1d458f1`, bump in `5d3076c`), archived from the clean release worktree

## What changed

Reported: "generate a dog" made the image, but afterwards the chat could not continue until Load model was pressed, and the next request, "write a animation html", generated the dog again.

- `generate_image` returns as soon as diffusion starts, and diffusion unloads the chat model. The chat still asked that model for a follow-up reply, which died mid-stream. The follow-up is now skipped for a started image.
- The image message now carries a caption (`Here's the image of "…"`, or the failure), and the selected chat model reloads once the diffusion run ends.
- Later turns show the model only the caption for a finished image turn, not the `generate_image` call and its result. With them left in, LFM3 called `generate_image` again for the next request.

## Verification actually run

| Check | Result |
| --- | --- |
| Mac replay (`lfm3-image-turn-replay.py`): LFM3-1.7B-Uncensored-AD-Q6_K, llama.cpp b11960 `llama-server`, temp 0.1 / top-k 50 / repeat 1.1, thinking off; "write a animation html" after "generate a dog" | `generate_image` called: before the fix 5/5 (both history shapes), caption with call and result kept 10/10, **caption only (shipped) 1/10**, fresh chat 1/5 |
| Same, thinking on | 0/5 for every variant, including before the fix |
| Archive (Xcode 27.1, `/Applications/Xcode.app`), `verify_appstore.py --distribution --expected-version 2.1.3 --expected-build 97` | passed; bundle file list matches 96 apart from symbol UUIDs |
| What to Test read-back, 11 locales | all match `testflight-notes.json` (`asc-test-notes-readback.json`) |

Not run: the flow on a physical iPhone; `AssistantActivityCardTests` (the hosted tests need a device; the archive compiled the app code they test). The replay uses a short stand-in system prompt with the app's LFM3 tool list, not the full persona prompt. The model still calls `generate_image` for "animation html" in about 1 in 10 runs with thinking off, the same rate as a fresh chat; that is the existing tool-choice behaviour noted for 96.
