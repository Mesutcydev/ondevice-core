# Functionality and logic audit — build 59 — 24 September 2026

Companion to the [UI/UX release audit](UI_UX_RELEASE_AUDIT_2026-09-24.md).

**Scope.** This audit covers the logic behind what users do and the data they keep:

- the chat request lifecycle: send, stop, retry, delete, switch;
- conversation persistence and iCloud sync;
- "Wipe all data";
- model download, switching and deletion;
- auto-titling;
- crash-prone constructs.

The services layer is about 73,700 lines, so this was a targeted read of the flows that can lose data, waste the model runtime, or contradict what the UI says. Voice, Lens, the Local API and memory residency were covered in the build 52 and Round 2 audits and were not reopened.

## Fixed in this pass

| # | Finding | Fix |
| --- | --- | --- |
| L1 | **"Clear conversation" deleted nothing.** It is a destructive menu item behind a confirmation, but it called `clearConversation()`, which saves the chat to history and starts a new one. The chat stayed in history (and in iCloud), so a user who "cleared" something private still had it. | Renamed to **Delete conversation**. It now calls `deleteCurrentConversation()`, which stops generation, resets the thread and calls `store.delete(id:)`. That records a sync tombstone so iCloud removes the copy too. The confirmation now states what is deleted. `CodingAssistantView.swift` |
| L2 | **iCloud sync could drop new chats or replies.** `pullThenPush()` snapshotted local conversations, then `await`ed CloudKit deletes inside the merge loop, then called `replaceAll`. Because the type is `@MainActor`, those awaits let the chat save a finished reply or create a conversation, and `replaceAll` then overwrote the store with the stale snapshot. | The merge now runs without suspension points. Tombstone deletes are collected and performed after `replaceAll`. `CloudSyncService.swift` |
| L3 | **"Wipe all on-device data" left the open chat behind.** The wipe empties `ConversationStore`, but the chat view keeps the open transcript in `@State`. On the next background transition, `persistCurrentConversation()` wrote it back. | The wipe posts `.onDeviceDataWiped`. The chat view discards its transcript, draft and conversation ID without saving. `WipeAllDataService.swift`, `CodingAssistantView.swift` |
| L4 | **An unsaved new chat was unreachable from the new drawer.** Recents list only saved conversations. (Found by `testSidebarDestinationsAndModelReadiness`.) | The drawer shows a "Current chat" row when the open chat is not yet in Recents. |

All four compile in the production target. L4 is covered by the UI test. L1–L3 are code-path fixes that could not be exercised in the simulator, where Core AI is unavailable. Verify them on device with a paired iCloud account: send, sync, delete, wipe, then background the app.

## Open findings

| # | Pri | Finding | Evidence | Recommendation |
| --- | --- | --- | --- | --- |
| L5 | P1 | **Browsing old chats reloads models.** `loadConversation()` calls `assistant.switchTo(storedModel)`, which unloads the current runtime and loads the chat's original model: gigabytes of weights, seconds of thermal load. It fires even if the user only wants to read. Starting a new chat then switches back to the default through `restoreDefaultModelForNewConversation()`, a second full load. This contradicts the app's own rule that browsing never claims an inference runtime (`ContentView.swift`). | `CodingAssistantView.swift` `loadConversation`, `CodingAssistantService.swift:3674` | Record the chat's model as *pending* and switch on the next send, or offer "Continue with Ornith 1.5?" in the composer. |
| L6 | P1 | **Wipe blocks the main thread.** `WipeAllDataService.wipeAll()` is `@MainActor` and runs `dirSize` and `removeItem` synchronously over every model folder, which can be tens of GB. The UI freezes for the duration. Loaded models are not unloaded first. | `WipeAllDataService.swift:26-60` | Unload runtimes, then move the file work to a detached task with a progress state. |
| L7 | P2 | **The wipe does not remove iCloud copies.** It disables sync, but the CloudKit records remain, and re-enabling sync restores the "wiped" conversations. The dialog promises that conversations are deleted. | `WipeAllDataService.swift:138`, Settings dialog copy | Delete the CloudKit records when sync was on, or say in the dialog that iCloud copies stay. |
| L8 | P2 | **Deletions do not propagate across devices.** Tombstones exist only on the device that deleted. Device B still has the conversation locally, sees it missing remotely, and pushes it back up. Sync also fetches at most 500 records with no cursor paging. | `CloudSyncService.swift:77, 151-160` | Store tombstones in CloudKit (a deleted flag on the record) and page with `CKQueryOperation.Cursor`. |
| L9 | P2 | **Model deletion changes selection before the delete succeeds.** `handleDeletion` resets selections and unloads before `model.delete()`. A failed delete leaves files on disk with the selection already cleared. The default chat model is reset to `presets.first`, which may not be installed, so the next chat opens in the "Choose model" state. | `ModelDownloadCenter.swift:1066-1096` | Delete first, then reset. Fall back to another *installed* chat model. |
| L10 | P2 | **Auto-title competes with the next turn.** After every first reply, `ConversationTitler` runs another `generate()` on the shared runtime. A follow-up sent immediately, a Local API client or voice can hit a busy model. | `ConversationTitler.swift:18-70` | Defer titling until the runtime is idle, or derive the title without inference. |
| L11 | P3 | Stale guidance: the large-download notice says "Use Models → Storage Cleanup". That screen is now Device → Manage storage. | `HFModelDownloadManager.swift:447` | Update the copy. |

## Verified healthy

- **Request ownership.** Every async chat callback checks `accepts(request)` against `operationID`, the conversation and the model. `stopGeneration()` rotates the ID, so late web, document, image or tool results and streamed tokens cannot land in the wrong chat, including a deleted one.
- **Preparing flags.** Every early exit in the send path clears `submissionPreparing`. Declining web access falls back to answering offline.
- **Download preflight.** Free space is checked before a transfer, with a floor that avoids false refusals. Imports check space too.
- **Crash hygiene.** The only `try!`, `fatalError` and `as!` sites are the standard `layerClass` cast, the Keychain `SecIdentity` cast, a `required init(coder:)`, and a FastVLM path previously verified unreachable.
- **Deletion from the model detail sheet** is confirmed and disabled while a reply is streaming.

## Component updates worth adopting

| Component | In the app | Current upstream | What it unlocks |
| --- | --- | --- | --- |
| **llama.cpp** | commit `7ef790f9` (27 Jul 2026). The `ggml 0.17` version string is not bumped per release, so it does not date the tree | `53ed051` (24 Sep 2026) | The vendored build **already** runs Gemma 4 (plus its MTP assistant drafter), Qwen 3.5/3.6, DeepSeek 4 and EAGLE3 GGUFs, and exposes `llama_model_n_layer_nextn`. The two newer months add `LLAMA_CONTEXT_TYPE_MTP` and the `load_mtp` model flag, further architectures (MiniMax-M3, Granite-Switch, DeepSeek-v4 indexer), Metal MoE/SSM fusion and fixes. The public API the app uses is source-compatible: additions only. Upstream is staged at `ThirdParty/llama.cpp.upstream-53ed051-2026-09-24`; rebuilding its xcframework needs approval to run its build script. MTP decoding itself lives in llama.cpp's `common` library (`common_speculative`, `draft-mtp`), which the xcframework does not ship. |
| **whisper.cpp** | 1.8.4 | 1.9.4 (≈ 11 Sep 2026) | NVIDIA **Parakeet** ASR support (1.9.0), included in `build-xcframework.sh` since 1.9.2; decoder-reseeding fix; Metal tuning for M-series GPUs; language detection. Check the `whisper_full_params` and VAD C API changes when upgrading. |
| **Apple Foundation Models (iOS 27)** | PCC integration present | Image input on-device and on PCC (32K context on PCC); a pluggable `LanguageModel` protocol; free PCC access for small developers | `mlx-swift-lm`'s **MLXFoundationModels** adapter exposes MLX models as `LanguageModel`s. The app could run local and PCC models behind one `LanguageModelSession`, with `@Generable` output and tool calling. |
| **mlx-swift-lm** | 3.31.4 | 3.31.4 (current) | Up to date. Open PRs to watch: Gemma 4 reasoning channels, a rewindable Mamba cache for speculative decoding, a cross-request prompt cache. |
| **Apple Core AI / coreai-models** | Pinned package + zoo catalog | Curated catalog, export recipes, agent skills | The community zoo now lists 66 models (LLM, VLM, OCR, ASR, TTS). There is a known SDPA crash for ≥16 heads × 512 Q (apple/coreai-models#27); check any new zoo entries against it. |
| **Edge0** | Native foundation after reference `0700e653` | Repo updated 20 Sep 2026; also ships **Audio8-TTS** (0.1B/0.6B, zero-shot voice cloning) and **Audio8-ASR-Infinite** (streaming, 240–560 ms latency) | Audio8 models are candidate on-device voice engines alongside Kokoro. They need a Core AI/MLX port; the published 0.1B build is ONNX INT8. Edge0's accuracy figures are self-reported. |
| **Models to consider** | Gemma 4 via Core AI zoo/MLX; Qwen 3.5 | Gemma 4 E2B/E4B are the consensus phone picks; K2 Horizon 0.9B–7B (Apache-2.0, 3 Sep 2026); no phone-sized Qwen 3.6 yet | Gemma 4 E2B/E4B GGUFs already load with the vendored llama.cpp; add them to the curated GGUF list. Watch K2 Horizon for GGUF/MLX builds. |

Sources: [llama.cpp release history](https://freedom.tech/project/llama-cpp/) · [llama.cpp MTP timeline](https://dev.to/oooocean66/mtp-in-practice-benchmarking-gemmas-speculative-decoding-on-a-real-gpu-242) · [Qwen 3.6 MTP in llama.cpp](https://mer.vin/2026/05/run-qwen-3-6-mtp-in-llama-cpp-faster-local-inference-with-built-in-speculative-decoding/) · [whisper.cpp v1.9.4](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.4) · [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases) · [Meet Core AI, WWDC26](https://developer.apple.com/videos/play/wwdc2026/324/) · [Apple newsroom, June 2026](https://www.apple.com/newsroom/2026/06/apple-aids-app-development-with-new-intelligence-frameworks-and-advanced-tools/) · [What's new in Foundation Models, WWDC26](https://developer.apple.com/videos/play/wwdc2026/241/) · [Bring an LLM provider to Foundation Models](https://developer.apple.com/videos/play/wwdc2026/339/) · [MLXFoundationModels README](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXFoundationModels/README.md) · [mlx-swift-lm releases](https://github.com/ml-explore/mlx-swift-lm/releases) · [apple/coreai-models](https://github.com/apple/coreai-models) · [coreai-model-zoo](https://github.com/john-rocky/coreai-model-zoo) · [Edge0-AI](https://github.com/Edge0-AI) · [Audio8 TTS](https://github.com/Edge0-AI/Audio8_TTS) · [Audio8-ASR-Infinite](https://huggingface.co/Edge0/Audio8-ASR-Infinite) · [Qwen 3.6 vs Gemma 4](https://llmcheck.net/blog/qwen-36-vs-gemma-4-deep-technical-comparison/) · [K2 Horizon](https://cellcog.ai/blog/k2-horizon/)
