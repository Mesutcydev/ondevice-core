# Local AI studio audit — 27 September 2026

The strongest direction is a dependable, private workspace for conversations,
documents, camera input, and voice, with clear model choices and recoverable
operations. The current app already has most of the necessary features. The
next release should concentrate on cancellation, deletion, setup, and evaluation
before expanding the runtime or model list.

This audit examines the **current working tree, build 74**, including its
pre-existing uncommitted changes. It preserves the current conversation home,
leading sidebar, retained workspaces, and leading keyboard-dismiss control.
No production code, dependency pins, signing settings, or releases were changed.
Source findings below describe concrete code paths; they are not claims of
physical-device reproduction. The simulator host cannot validate CoreAI,
inference performance, actual camera/audio operation, CloudKit accounts, or Jetsam.

**Work covered**

- [x] Read current architecture and navigation guidance; recheck earlier audits.
- [x] Inspect generation ownership, persistence, wipe, sync, downloads, imports,
      model deletion, retrieval, benchmarks, and local API boundaries.
- [x] Run portable checks, voice tests, and simulator host contracts.
- [x] Finish selected UI flows and inspect their native screenshots.
- [x] Record the production device compile result.
- [x] Verify upstream update candidates and current competing product features.
- [x] Produce a prioritized implementation sequence with acceptance criteria.

**Fixes to prioritize**

P1 means fix before treating the release as reliable for user data and daily
work. P2 means a significant correctness or usability improvement. Effort is a
rough relative estimate: S = one focused change, M = several related paths,
L = a subsystem change with integration testing.

| ID | Priority | Finding | Effort |
| --- | --- | --- | --- |
| A1 | P1 | Stop does not invalidate requests waiting for load or a busy runtime | M |
| A2 | P1 | Wipe can retain private memory and allow work to restore deleted data | L |
| A3 | P1 | Reading a conversation starts model switching and loading | M |
| A4 | P1 | Declared native submodules have no tracked Git entries in this snapshot | M |
| A5 | P2 | Conversation deletion does not converge across devices | L |
| A6 | P2 | Cloud sync drops the query cursor and can start overlapping runs | M |
| A7 | P2 | Model deletion checks the default instead of every active owner | M |
| A8 | P2 | Automatic titles compete with foreground inference | M |
| A9 | P2 | A benchmark can mix models and record only the final model identity | M |
| A10 | P2 | “Search chats” cannot find text in older turns | M |
| A11 | P2 | The active package does not supply translations for its English UI | M |
| A12 | P2 | Published setup requirements disagree with the current app target | S |
| A13 | P2 | Composer geometry disagrees across code, tests, and documentation | S |

1. **A1 — Make cancellation cover the whole request.**
   [CodingAssistantService.swift:2360](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/CodingAssistantService.swift:2360)
   creates an untracked task to wait for a busy model. The lazy-load branch at
   line 2406 does the same. Both can call `generate` later, while
   [stopGeneration:3780](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/CodingAssistantService.swift:3780)
   cancels the backend tasks but not these waiting tasks. A request submitted
   during a load or another generation can therefore begin after Stop. View
   request IDs discard stale callbacks, but do not prevent the unwanted work.
   Give preparation, waiting, and decoding one request identity and cancellation
   owner. Recheck that identity, the captured model, and cancellation after each
   suspension. Complete callbacks exactly once. **Acceptance:** hold a load or
   decode, enqueue a request, stop/delete/background, then release the hold; no
   new decode begins and all callers finish.

2. **A2 — Treat wipe as a coordinated operation with a truthful result.**
   [WipeAllDataService.swift:112](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/WipeAllDataService.swift:112)
   removes persisted memory/snippet/benchmark keys but leaves already loaded
   `MemoryStore.facts`, `SnippetStore.snippets`, and `BenchmarkService.history`
   alive. Only the chat view observes the wipe notification. In particular,
   [MemoryStore.swift:82](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/MemoryStore.swift:82)
   can still inject wiped facts into the next prompt; a later mutation can save
   them again. Wipe also neither drains model owners nor invalidates CloudKit,
   model import, or background download work. A suspended cloud pull can later
   `replaceAll`, and a download finalizer can recreate its destination directory.
   Disk walks/deletes run on MainActor, errors are discarded, and Settings still
   reports success. First invalidate operation generations, stop/drain writers
   and runtimes, clear each store through its owning API, then delete off-main
   and return verified successes/failures. Explicitly explain whether iCloud
   copies remain. **Acceptance:** wipe with loaded memories, an in-flight sync,
   import, download, benchmark, and chat; release delayed completions and relaunch.
   Nothing reappears, no old facts enter a prompt, and injected deletion failures
   produce an incomplete result rather than “Wiped.”

3. **A3 — Separate a conversation's preferred model from runtime residency.**
   [CodingAssistantView.swift:886](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Views/CodingAssistantView.swift:886)
   opens history and launches `switchTo`; starting a new chat also restores the
   default by switching. This performs expensive work just to read saved text.
   Rapidly opening chats can additionally encounter the service's “already
   loading” guard after navigation has moved on. The sidebar dispatches
   `openConversation` without the voice interruption confirmation used by an
   explicit model change. Keep the conversation's preference pending and resolve
   it on Send; show the intended model in the composer and use the existing
   exclusive-operation policy. **Acceptance:** open 20 mixed-model chats while
   voice is minimized: zero model loads/unloads and no voice interruption;
   sending uses the chosen conversation's model or an explicit recovery choice.

4. **A4 — Restore reproducible native dependency inputs.**
   `.gitmodules` declares both native runtimes, but `git ls-files --stage` and
   `git ls-tree HEAD` return no entries for either path; `git submodule status`
   is empty. The local `ThirdParty/` copies are excluded from this worktree's
   index. [build_native_frameworks.sh:18](/Users/m/Desktop/OnDeviceMax/scripts/build_native_frameworks.sh:18)
   assumes `submodule update` supplies them. A fresh checkout of this tracked
   snapshot consequently lacks the inputs the documented build requires.
   Restore pinned gitlinks or implement an explicit fetch of immutable revisions,
   preserving upstream repositories and notices. Match the SBOM and record source
   revisions plus framework hashes in build evidence. **Acceptance:** a clean
   disposable checkout obtains the exact sources and builds without existing
   local frameworks; hygiene CI fails if either pin disappears. This finding
   concerns this snapshot, not a claim about every published release.

5. **A5 — Synchronize deletion records.**
   [CloudSyncService.swift:149](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/CloudSyncService.swift:149)
   hard-deletes cloud records while tombstones live only in local UserDefaults.
   Device B, with an older local copy, treats the missing cloud record as a new
   upload and restores it. Persist deletion state in the sync protocol, define
   conflict/retention rules, and migrate existing records. **Acceptance:** delete
   on A, sync B after being offline, then sync A; the chat remains deleted. Test
   a legitimate newer edit separately. Do not equate 90 elapsed days with proof
   that every device has synchronized.

6. **A6 — Make cloud synchronization complete and serialized.**
   [CloudSyncService.swift:77](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/CloudSyncService.swift:77)
   discards the cursor after at most 500 records, so older cloud-only history
   never reaches a new device. At line 45, account availability is awaited before
   `isSyncing` is set, allowing two callers past the initial guard. Hold one sync
   ownership token before the first await, page to exhaustion, and recheck
   consent/cancellation before merge and upload. Report record/deletion failures
   as partial sync. **Acceptance:** 1,201 records synchronize completely, two
   simultaneous starts run one operation, and disabling sync during a held pull
   prevents a later merge/upload.

7. **A7 — Delete models through actual runtime ownership.**
   [ModelDownloadCenter.swift:1194](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/ModelDownloadCenter.swift:1194)
   resets selections before deletion succeeds. Its assistant check compares
   `AppSettings.assistantModelID`, although conversation-specific switches can
   leave another model active without changing that default. A failed delete
   loses the preference; a non-default active model may miss the unload path.
   Acquire exclusive ownership, drain each actual owner, remove files, then
   commit selection/registry changes. On failure retain the user's preference
   and show the accurate unloaded/error state. Select an installed compatible
   fallback or ask for a choice. **Acceptance:** default A, active B, delete B;
   B is drained, the file removal outcome and UI agree, and an injected filesystem
   failure does not silently select an undownloaded model.

8. **A8 — Keep title generation out of the user's critical path.**
   [ConversationTitler.swift:33](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/ConversationTitler.swift:33)
   takes the shared assistant immediately after the first reply. A quick follow-up,
   voice turn, or API request can contend with it; a 16-token output limit does
   not bound the prefill cost of a long first message. Use an immediate local
   title and optional low-priority enrichment with cancellation and a bounded
   input. Commit only if the title and conversation version still match the
   captured values. **Acceptance:** a follow-up always takes precedence; rename,
   delete, or wipe during enrichment cannot be overwritten by completion.

9. **A9 — Make evaluation results attributable.**
   [BenchmarkService.swift:314](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/BenchmarkService.swift:314)
   checks readiness at entry, yields between prompts, and assigns the model from
   `assistant.activeModel` only at the end. Another workspace can change the
   runtime between runs. Results also omit model artifact identity, runtime
   revision, context/cache settings, and sampling configuration. Capture an
   immutable run descriptor; hold the existing exclusive runtime ownership or
   abort on any identity change. Preserve the new runtime-token versus stream-chunk
   distinction in all displays/exports. **Acceptance:** attempting a model switch
   between prompts produces a cancelled run or explicit confirmation, never a
   mixed result labelled as one model. Compare repeatable settings and retain
   raw runs, not just averages.

10. **A10 — Search the transcript.**
    [ODConversationsHome.swift:75](/Users/m/Desktop/OnDeviceMax/Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODConversationsHome.swift:75)
    matches only title and subtitle. The subtitle is the last visible message
    preview from [ODBridge.swift:857](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/ODBridge.swift:857).
    A distinctive phrase in an earlier turn is invisible to “Search chats.”
    Add a local transcript search service with matching excerpts and message
    anchors, updating changed conversations only. **Acceptance:** find a term
    present only in an old turn and jump to that turn; deleted chats disappear
    from results and large histories do not block typing.

11. **A11 — Complete localization across the package boundary.**
    The host exposes 15 explicit languages through
    [LocalizationService.swift:22](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Services/LocalizationService.swift:22),
    while the active package uses English literals and has no `.xcstrings` or
    `.strings` resources. Host dictionary translation does not translate those
    literals. Add package string resources with the correct bundle and connect
    the selected locale consistently; migrate incrementally. **Acceptance:**
    Turkish, a long-text language, and Arabic render the home, drawer, model
    states, and recovery actions consistently, including RTL gestures and
    accessibility labels. Changing language must preserve drafts.

12. **A12 — Publish the supported platform accurately.**
    [project.yml:96](/Users/m/Desktop/OnDeviceMax/project.yml:96) targets iOS 27;
    README still advertises iOS 18+ and Xcode 26+, while setup gives production
    simulator-test commands despite the device-only CoreAI dependency.
    Document the actual Max requirements and the `QA/NativeUI` path. If older
    iOS support is a product requirement, scope a separately verified runtime
    configuration before advertising it. **Acceptance:** a new contributor can
    follow one consistent setup/test path with the declared SDK.

13. **A13 — Reconcile the composer contract before claiming a green suite.**
    The current package test run failed
    `composerHeightBudgetFollowsContentRows` at
    [PresentationContractsTests.swift:69](/Users/m/Desktop/OnDeviceMax/Packages/OnDeviceUI/Tests/OnDeviceUITests/PresentationContractsTests.swift:69)
    and line 72: code computes **120 / 168 pt**, tests require **116 / 164 pt**,
    and [LayoutMetrics.md:66](/Users/m/Desktop/OnDeviceMax/Packages/OnDeviceUI/Documentation/LayoutMetrics.md:66)
    still describes **108 / 156 pt**. The real keyboard-placement UI test passed,
    so this is verified contract drift, not proof of a visible keyboard defect.
    Establish the intended current padding, then align the constants, independent
    expected dimensions, and documentation. Do not simply loosen assertions to
    silence the failure. **Acceptance:** the package suite passes and measured
    compact/large-text composer captures meet the agreed geometry.

**Improvements that would most strengthen the product**

| Order | Improvement | Build on | Definition of success |
| --- | --- | --- | --- |
| 1 | Guided first successful local answer | `OnboardingOnePager`, existing picker and `DeviceTierAdvisor` | Choose a task; see one suitable default with size, license, and fit explanation; explicitly download; try a useful prompt. Measure completion and time to first useful answer. Skip remains available. |
| 2 | Offline readiness | Existing model/install/runtime states | Chat, vision, transcription, speech, and images each show missing/downloaded/validated status and one repair action. An explicit offline smoke test records what actually worked. |
| 3 | One model-management path | Current Models workspace | On device, Discover, imports, transfers, and storage share the same detail/actions. Other entry points deep-link into it. Separate installed, selected, loaded, compatible, and measured states. |
| 4 | Document workspaces | Existing KB, source snapshots, conversations | Select documents per conversation; inspect supplied page/excerpt; distinguish retrieved evidence from verified claims. Evaluate multilingual and scanned-PDF cases before promising support. |
| 5 | Reusable task presets | Existing Persona and settings stores | “Study documents,” “Write,” “Code,” and “Translate” can bind optional model preference, document scope, and voice. Tool/network consent remains visible and consequential actions still require approval. |
| 6 | Trustworthy model comparison | Benchmark and quality-evaluation services | Report success rate, first-token latency, sustained rate, peak memory, thermal state, and quality fixtures with provenance. Label estimates and chunk counts honestly. |
| 7 | Everyday iOS integration | Existing App Intents, share extension, Spotlight | Useful summarize/rewrite/explain Shortcuts, stable share-to-chat, transcript search, export, and undoable chat deletion. Add hardware-keyboard commands for iPad/Catalyst. |

Preserve the current visual direction. The examined light/dark and large-text
fixtures support refining the existing shell. At the largest text size, the
voice summary still truncates the locale; let that secondary line wrap. First-run
model guidance is more valuable than another navigation redesign. The existing
model-picker helper also contains old “bundled camera”/“Models tab” copy, so reuse
its admission logic without copying that wording into a new onboarding flow.

Two performance candidates deserve measurements before structural changes:

- [ConversationStore.swift:194](/Users/m/Desktop/OnDeviceMax/IOSLocalLLM/Models/ConversationStore.swift:194)
  encodes the full history and requests a complete Spotlight reindex on saves.
  Measure growing histories; use incremental indexing and serialized persistence
  if the trace confirms avoidable latency. Task creation alone does not prove
  that encoding runs off-main.
- `ODStore` is a broad `ObservableObject` shared across retained workspaces.
  `ODBridge` already coalesces refreshes and caches some signatures. Profile
  streaming first; split hot state or adopt per-property observation where it
  reduces measured invalidation, while retaining drafts and lifecycle signals.

For retrieval, `OnDeviceEmbedder` is English by default and can fall through
from sentence to word embeddings for an individual input; the persisted index
does not identify embedding family/revision/language. Add that provenance and
an explicit reindex path before offering multilingual retrieval. This is a
correctness/evaluation task, not grounds for claiming measured poor recall.

**Updates checked against primary sources**

| Component | Current evidence | Recommendation |
| --- | --- | --- |
| MLX Swift LM | Lockfile pins 3.31.4 (`bd4b743…`); upstream still marks that tag latest | Keep the tag initially. Evaluate specific later commits against failing fixtures rather than moving wholesale to main. [Official release](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.31.4). |
| whisper.cpp | Local CMake source reports 1.8.4; upstream marks 1.9.4 latest | Evaluate a pinned 1.9.4 upgrade after restoring source/binary provenance. Relevant changes include decoder reseeding; Parakeet support arrived in 1.9.0. Verify native API changes, VAD, repeated turns, language detection, cancellation, and phone memory. [1.9.4 releases](https://github.com/ggml-org/whisper.cpp/releases), [Parakeet introduction](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.0). |
| llama.cpp | SBOM records `7ef790f…`; the local copy has no tracked gitlink. Upstream lists b11205 as a prerelease and has v0.4.0 release notes | Establish exactly what source produced the linked framework, then evaluate a pinned update. The newest daily tag is not evidence of an iPhone benefit. Test chat templates, vision, UTF-8 streaming, tools, cache compatibility, cancellation, and peak memory. [Release list](https://github.com/ggml-org/llama.cpp/releases), [v0.4.0](https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.0). |
| PrismML MLX fork | Exact revision `e40e0a5…` in the lockfile | Preserve required one-bit kernels and verify model parity before replacing the fork with upstream. |
| CoreAI package | Vendored revision `938d0b8…` plus documented symbol, hybrid-state, fixed-shape, and streaming patches | Review every local patch during an update. Require device launch verification as well as compile success; retain the FoundationModels symbol check. [Local patch record](/Users/m/Desktop/OnDeviceMax/Packages/coreai-models/COREAI_PIN_PATCH.md). |

No dependency, model weights, or new third-party assets were added. A model
catalog entry should identify license, immutable source, supported backend,
device suitability, and verification status. Keep experimental large models
clearly marked until full-turn quality, memory, thermal, and cancellation results
exist on the intended iPhone.

Current competitors reinforce the priorities above: PocketPal documents model
discovery, reusable Pals, tools, TTS, benchmarks, and localization; Private LLM
organizes selection by task/device and provides Shortcuts; LM Studio's Locally
offers optional encrypted access to a paired desktop's models. These are vendor
feature descriptions, not comparative quality or speed measurements. The app's
existing Mac tool bridge must not be described as desktop inference without a
separate verified inference route. [PocketPal](https://github.com/a-ghorbani/pocketpal-ai),
[Private LLM](https://privatellm.app/en),
[Locally / LM Link](https://lmstudio.ai/blog/locally-lm-link).

**Delivery sequence**

1. **Reliability release:** A1–A7, deterministic local titles/foreground priority,
   runtime ownership regression fixtures, and clean-build inputs. Preserve the
   current memory/thermal/residency refusals. Test wipe and CloudKit on devices.
2. **First-use release:** guided model choice, unified management, offline
   readiness, full transcript search, localization, and accurate platform docs.
3. **Studio release:** scoped documents, task presets, attributable benchmarks,
   quality fixtures, and a small Shortcuts gallery. Run native dependency upgrades
   independently so their regressions remain diagnosable.

Release criteria should include zero stale request starts, zero wiped-data
restoration, correct cross-device deletion, successful offline core tasks, and
no crashes through repeated model switches. Record first-token p50/p95,
stop-to-idle time, peak footprint, and sustained thermal behavior on the same
device/model/settings. Establish measured baselines before setting speed claims.

**Validation evidence**

- `scripts/test_memory_budgets.sh`: **134 assertions passed**.
- `scripts/test_studio_policies.sh`: **17 assertions passed**, with a writable
  Clang module-cache path for the sandbox.
- `scripts/validate_open_source.sh`: **passed**. Its current checks do not detect
  the missing native gitlinks; this is why a hygiene pass is not build proof.
- VoiceAgentOrb: **25 tests passed** using `--scratch-path build/audit-voice`.
  The first run hit the documented stale Metal toolchain path; a fresh build
  resolved it without source changes.
- Regenerated `QA/NativeUI`: **21 host-contract tests passed** (7 XCTest and
  14 Swift Testing), including attachment delivery and request ownership.
- Selected native UI flows: **5 passed**, including the eight-screen matrix in
  light/dark and default/largest accessibility text, chat search/pin/open/new,
  draft/attachment retention, keyboard placement, and invalid progress values.
  Simulator: QA iPhone 17 Pro Max, iOS 27, 440-point viewport. Inspected nine
  representative screenshots; ten original captures were retained under
  [audit screenshots](/Users/m/Desktop/OnDeviceMax/build/audit-2026-09-27/screenshots).
  [UI result bundle](/Users/m/Desktop/OnDeviceMax/build/NativeUIReview/DerivedData/Logs/Test/Test-NativeUIReview-2026.09.27_10-35-04-+0300.xcresult).
- OnDeviceUI package: **11 passed, 1 failed (two assertions)**; see A13.
  [Package result bundle](/Users/m/Desktop/OnDeviceMax/Packages/OnDeviceUI/.build/ContractTests/Logs/Test/Test-OnDeviceUI-2026.09.27_10-42-31-+0300.xcresult).
- Production device Debug compile: **BUILD SUCCEEDED**, using Xcode 27.0
  (`27A5218g`), `generic/platform=iOS`, existing pins, and
  `CODE_SIGNING_ALLOWED=NO`. This is an incremental local build using available
  native frameworks, not a clean-checkout or physical launch result.
  [Build log](/Users/m/Desktop/OnDeviceMax/build/audit-2026-09-27/device-build.log).

Overall: **62 tests passed, 1 test failed; 151 portable assertions passed**,
plus repository hygiene and the production build. No physical-device performance
or inference-quality claim follows from these results.

Existing fixes were rechecked instead of relisted as new work: KB imports have
cancellation/generation checks and a commit-time capacity gate; chat grounding
runs retrieval off-main and saves inspectable source excerpts; model import has
copy-mode multi-file and exact Edge0-family handling; model progress is bounded;
benchmark callbacks have an ordered consumer and token-count provenance. The
reviewed local API code authenticates before buffering large bodies, caps
requests/connections, and retains cancellation on disconnect. This is a targeted
review, not a full security assessment or network protocol test.

The present CI workflow runs repository hygiene and the voice package. Add the
portable policies, OnDeviceUI contracts, and native host tests to an appropriate
Xcode runner, then a separate device build/launch gate. The source-backed races
above cross real services that the simulator fixtures intentionally replace.
Passing presentation tests therefore does not close those findings.
