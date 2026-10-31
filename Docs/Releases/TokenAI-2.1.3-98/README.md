# Token: Local AI Studio 2.1.3 (98) — App Store candidate

The assistant starts an image only when the user asked for one. Build 97 was reported still repeating images on an iPhone. Uploaded 2026-10-31, **VALID**, internal beta via the "Test" group (build ID `2c73b611-0a4d-41f8-838d-37d9298446c4`). What to Test is set in 11 locales and read back (`asc-test-notes-readback.json`). Version 2.1.3 is still in review with build 97; 98 is not attached.

- IPA: 94,635,838 bytes, SHA-256 `d5c79bae3e61ce63a265f040839796ea529cd2f36e4763961886babe8345d7f7`
- Source: `5fac04b` on branch `lfm3-omni` (fix in `ddc2713`), archived from the clean release worktree with the 97 command (top of `build/appstore/2.1.3-98/archive.log` there)

## What changed

The report came from TestFlight 97 with LFM3 1.7B Uncensored AD. After "generate a apple image" produced the apple and its caption, "Need a animated background html code" ran a web search (which pushed the chat into context compaction) and then asked for another apple image.

- Before showing the image approval, the app checks the user's latest message (`AssistantActivity.asksForImage`). It needs either an image word, or a generate/create verb with no code word, in any of the app's 11 languages.
- If the message has neither, the app declines the call itself ("The user declined this generate_image request: …"). A declined tool turns tools off for the rest of that turn, so the model answers in text. The chat shows a "Generate Image cancelled" chip.
- If the heuristic misses, the model answers in text and the user can ask again with the word "image".

## Verification actually run

| Check | Result |
| --- | --- |
| `asksForImage` cases (`test_imageToolNeedsTheUserToAskForAnImage` and more), run on the Mac with `swift` on an extracted copy | 21/21: 13 image requests in 11 languages allowed; the reported HTML requests, "make it shorter", "tell me about apples" and code requests declined |
| Mac replay (`lfm3-declined-image-replay.py`): LFM3-1.7B-Uncensored-AD-Q6_K, llama.cpp b11960, apple image turn, then the HTML request with a declined `generate_image`, no tools | HTML with no tool call: 5/5 thinking off, 5/5 thinking on |
| Archive (Xcode 27.1), `verify_appstore.py --distribution --expected-version 2.1.3 --expected-build 98` | passed; bundle file list matches 97 apart from symbol UUIDs |

Not run: the flow on a physical iPhone; the hosted `AssistantActivityCardTests` (they need a device; the archive compiled the app code they test). The replay uses a short stand-in system prompt, not the full persona prompt.
