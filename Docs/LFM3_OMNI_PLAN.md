# LFM3-Omni rollout plan

Goal: add Liquid AI's LFM3-Omni-2B (text, image, audio, and video with its soundtrack in; text or speech out) without changing how existing models behave. One change per phase, one TestFlight build per phase, and every phase ends with the Phase 0 checklist.

Restore point: git tag `backup/pre-omni-2026-10-31` (2.1.3 (87), runtime b11938). Off-repo backup with restore steps: `/Users/m/Desktop/OnDeviceMax-backups/pre-omni-2026-10-31/RESTORE.md`.

## Rules

1. The normal runtime (llama.cpp b11558, `build/ClassifierNative`) and the default catalog do not change.
2. New behaviour is opt-in per model through capability flags read from the model (`mtmd_support_audio`, video config). Shared defaults (4,096-token GGUF context, prompts, sampling) stay as they are for every other model.
3. The b11938 runtime stays in `build/LFM3Native`. b11960 lives in `build/LFM3OmniNative`. Rolling back means building with the old folder again.
4. Each phase ships as its own TestFlight build with its own notes.

## Status

- Phase 0: restore point and backup done; baseline checklist below.
- Phase 1: shipped to TestFlight as 2.1.3 (88), the same app as 87 built against b11960 (branch `lfm3-omni`). Device comparison with 87 pending.
- Phase 2: shipped as 2.1.3 (89). `LFM3Catalog.omni` (Q4_0 + Q8_0 projector, revision `3d29af2a`) uses the LFM3 VL image path: same markup, same non-thinking prefix, same 4K exclusive Lens profile. It is offered and loadable only when the runtime exports `mtmd_get_video_config` (b11960), so a build switched back to b11938 hides and refuses it.
- Phase 3: video in chat. `OmniVideoInput.swift` ports b11960's mtmd-helper video reader to AVFoundation (frame picks, `<X.X seconds>` per 2 frames, each group's 16 kHz soundtrack slice after its frames); `OmniVideoFeed.swift` hands it to mtmd as one lazy video bitmap. b11960-only calls compile only with `LFM3_OMNI`, which the pre-build check ties to `build/LFM3OmniNative`; normal (b11558) and rolled-back (b11938) builds still compile. Omni gets a 16K context (other models keep theirs); clips start at 64 frames and retry with fewer when they do not fit.
  - Reference check (`scripts/test_omni_video_on_mac.sh`, real model on a Mac, `tools/mtmd/test-3.mp4`): the app path and b11960's `llama-mtmd-cli --video` produce the same 20 frames at 704×352, identical timestamps and identical soundtrack slices (160,000 samples); prompt tokens 2,651 vs 2,648 (the app's prompt pre-fills `<think></think>` and puts the marker on its own line). The answer describes the scene and quotes the dialogue.
  - Stored pixel size, as ffmpeg uses: a first version used AVFoundation's display size, which for non-square-pixel video gave 864×352 frames and 554 extra tokens. Unlike ffprobe, rotation is applied, so portrait iPhone clips are not squashed.
- Text-only answers: a real-model run showed Omni can open a text answer with `<|mixed_start|>` (text plus speech) and stop. Every Omni sampler now carries llama.cpp's text-only bias (`<|audio_start|>`, `<|mixed_start|>` at -inf); shipped in 2.1.3 (90) with Phase 3.
- Phase 4: Lens has a Clip mode, listed only when the host sets `canRecordLensClips` (LFM3_OMNI builds). It samples the live preview at 2 fps for 6 s while recording the microphone (16 kHz, under the shared audio-session lease; frames only without permission), then runs the same Omni video path (`OmniVideoSource.live`). The Mac harness replays a clip this way with `OMNI_HARNESS_SOURCE=live`.
- Phase 5: voice, all opt-in and only in LFM3_OMNI builds; Whisper stays the default, and System, Kitten and Kokoro voices are unchanged.
  - 5a: "omni" speech-to-text in Settings. Hold-to-talk records 16 kHz like Whisper and LFM3-Omni transcribes with the card's "Perform ASR in <language>." prompt.
  - 5b: an "LFM3 Omni" voice engine (female or male; the language follows each sentence, 19 languages). It renders the GGUF's own `tts` chat template and runs llama-tts's loop through b11960's `mtmd_helper_gen_audio` API (`OmniSpeech.swift`).
  - 5c: voice conversation. With Omni speech-to-text, Apple Speech still ends each turn and Omni re-transcribes the turn's audio. With the LFM3 Omni voice, Omni also writes the reply: speaking needs Omni in the visual slot, and loading it unloads the chat model (cancelling a reply still streaming), so one model stays resident. Omni requests run one at a time, so a reply finishes before its first sentence is spoken.
  - Mac checks with the real model (`scripts/test_omni_video_on_mac.sh`): transcription of `tools/mtmd/test-2.mp3` is accurate; speech output made 5.9 s of 24 kHz audio in 2.0 s, and transcribing it back returned the input sentence.
- Audit (xhigh code review of `lfm3-omni`) and fixes: Omni requests are serialised and carry the same thermal and background gates as `describe()`; the Omni voice alone switches voice chat to Omni replies; videos over 10 minutes are watched without sound (their soundtrack alone would fill the context); region-qualified language codes map to the template's names; Live Photos stay photos; each Omni turn resets the sampler's repetition window; Whisper is only selectable once installed; frames decode in one ordered pass and Lens frames are downscaled at capture; host tests keep running on macOS before 27. Not changed: Omni dictation and Omni-listening-only voice still unload the chat model per use (shared-slot design); Omni voice and STT are listed before the model is downloaded (first use explains the download).
- 2.1.3 (93): builds 89–92 never listed Omni in Models. Release builds use the App Store model policy, which drops any download whose repo is missing from `AuditedModelRevisions.json`, and Omni was missing; host tests run without that policy. Omni is now pinned there, and `verify_appstore.py --source` fails when an `LFM3Catalog` pin is not audited.
- Device checks: development and Ad Hoc installs on the test iPhone are refused by Apple's online authorization (`REJECT_PROFILE`, 0xe8008018), including freshly created profiles, so on-device unit tests cannot run. Every device check goes through TestFlight until Apple clears the team.
- Phase 6: no change. LFM3-VL stays in the catalog; Omni is not recommended over it until device results are in.

## Phases

| Phase | Change | Gate |
| --- | --- | --- |
| 0 | Restore point, backup, baseline below on 2.1.3 (87) | Baseline recorded |
| 1 | LFM3 builds use llama.cpp b11960 (`scripts/bootstrap_lfm3_omni_runtime.py`). No feature changes. | Host tests, compile gate, baseline matches on device |
| 2 | LFM3-Omni-2B as a new optional model (images first). LFM3-VL stays. | Image Q&A; switching Omni ↔ other models releases memory |
| 3 | Video in chat: AVFoundation frames and 16 kHz mono audio fed as mtmd video bitmaps (b11960 lays out the Omni video prompt via `MTMD_VIDEO_TEMPLATE_LFM3_OMNI`). Larger context for Omni only; frame cap with a notice. | Host tests for sampling and budget; a 10–20 s clip answered from picture and sound |
| 4 | Lens: short recorded clips through the same path | Old single-frame Lens unchanged |
| 5 | Voice: Omni speech-to-text option, then speech output, then live conversation. Whisper, Kokoro, Kitten and System voices stay. | Voice tests and soak test pass |

b11938 → b11960 is 22 commits. `llama.h` and the ggml headers are unchanged; `mtmd.h` and `mtmd-helper.h` only add API. The app calls `mtmd_init_from_file`, `mtmd_context_params_default`, `mtmd_support_vision`, `mtmd_bitmap_init`, `mtmd_bitmap_free`, `mtmd_input_chunks_init`, `mtmd_input_chunks_free`, `mtmd_tokenize`, `mtmd_helper_eval_chunks`, `mtmd_default_marker`, `mtmd_log_set` and `mtmd_free`, none of which changed.

## Phase 0 baseline (run on 2.1.3 (87) before installing 88)

Use the same phone, Low Power Mode off, the phone cool, and the app freshly opened. Keep the default sampling settings. For each row, note whether the answer is sensible, the tok/s shown under the reply, and any error, warning or crash.

| # | Model | Steps | 87: answer ok / tok/s / notes | 88: answer ok / tok/s / notes |
| --- | --- | --- | --- | --- |
| 1 | LFM3 1.7B | New chat: "Write three sentences about Istanbul." | | |
| 2 | LFM3 1.7B | New chat: "What time is it?" (should use the date/time tool) | | |
| 3 | LFM3 1.7B | New chat, attach `REV_DSB_beredskap_brosjyre_tyrkisk.pdf`: "Summarize document for me" | | |
| 4 | LFM3-VL 2B | Lens on a printed page: "Read the text" | | |
| 5 | LFM3-VL 2B | Chat with a photo: "Describe this photo" | | |
| 6 | Each other GGUF model you use (imported or catalog) | New chat: "Write three sentences about Istanbul." | | |
| 7 | Classifier features | Run one classification you normally use | | |
| 8 | Switching | LFM3 → another model → LFM3-VL Lens → back to LFM3; start a long reply and stop it | | |
| 9 | Voice | One dictation and one spoken reply | | |
