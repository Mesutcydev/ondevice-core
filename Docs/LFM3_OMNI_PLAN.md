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
- Phase 2: on branch `lfm3-omni`, not shipped. `LFM3Catalog.omni` (Q4_0 + Q8_0 projector, revision `3d29af2a`) uses the LFM3 VL image path: same markup, same non-thinking prefix, same 4K exclusive Lens profile. It is offered and loadable only when the runtime exports `mtmd_get_video_config` (b11960), so a build switched back to b11938 hides and refuses it.

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
