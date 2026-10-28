# Token AI logic audit — 26 October 2026

Fixes ship as 2.0.1 (76).

Scope: this working tree, which matches Token AI 2.0 (75), the build now on
the App Store. The audit read the code and ran the portable host checks.
Nothing here was run on a device: CoreAI-backed builds and IOSLocalLLMTests
are device-only.

Field signals: the only App Store review ("Each time I send a message it
crashes", 20 October) and the newest TestFlight crash (`GGUFEngine`,
`llama_grammar_accept_token`) both come from the 1.x Token AI codebase
(version 1.5 (70)), not this source. App Store Connect has no diagnostics for
build 75 yet.

## Fixed

| ID | Severity | Problem | Fix |
| --- | --- | --- | --- |
| L1 | P1 | Background transitions unload the chat model. The next send's lazy load reselected the **saved default**, so in any chat using another model the request failed: "The model changed while this request was waiting. Send it again." The retry then answered with the default model and re-saved the chat under it. | `generate()` loads the model the request was made for and waits out a model switch. The status-bar Load button does the same. |
| L2 | P1 | Same root, image path. Attaching an image in such a chat (text-only model) reloaded the default after visual grounding. `accepts(request)` then failed, and the composer stayed "preparing" until Stop. | The grounding reload keeps the request's model. |
| L3 | P2 | Voice mode restores the chat model "without loading, for the next send". That send loaded the default instead. Voice start also loaded the default rather than the model on screen. | Voice loads the active selection. |
| L4 | P2 | Making L1 correct exposed stale selections. A default set outside a chat (first-launch tier pick, model setup, "use for new chats", repaired defaults) never updated an idle live selection. | `CodingAssistantService` watches the saved default. A live selection still on the old default follows it, without loading, unless a model is resident or loading. |
| L5 | P1 | `ConversationStore` started empty whenever it couldn't read `conversations.json`, and the next save replaced the whole history. Two triggers: `completeUnlessOpen` refusing the read during a locked-device background launch (URL session relaunch), and a single undecodable record failing the entire decode. | A locked file defers loading until unlock and blocks saves meanwhile. An undecodable file is moved aside. Records decode individually: bad ones are skipped, and the original file is copied aside. |
| L6 | P2 | Wipe deleted `conversations.json` before retiring the store, so a save already in progress could write it back. A Spotlight reindex finishing late could also re-add wiped chats. | Writes are serialized against a wipe generation, and the store is cleared before the file is deleted. The reindex rechecks the generation. Copies set aside under L5 are wiped too. |
| L7 | P2 | Wipe ("deletes downloaded models … cache") left classifier models, saved classifier tasks (user-written instructions) and generated images behind. | All three are cleared. |
| L8 | P2 | Auto-titling sent the whole first message (unbounded prefill while the composer shows Stop), and it saved a partial title when the user tapped Stop. It also overwrote a rename made during titling. | The input is capped at 600 characters. Nothing is saved after a Stop or a title change. |
| L9 | P3 | The streaming code-fence rule turned prose after an inline fence ("wrap it in ``` fences.") into an empty code card, and the policy check still expected the old behaviour (failing). | A fence followed by prose stays text. A fence followed by a language token still mounts the card at once. |

## Assistant image input (review of the concurrent Codex change)

Lens keeps its own model and selection. In Assistant, every runtime now
answers about an attached image (see `Docs/ASSISTANT_IMAGE_INPUT_AUDIT_2026-10-26.md`):

| Runtime | How Assistant reads the image |
| --- | --- |
| Supported MLX text + vision (Qwen3.5, Bonsai 27B, Ternary Bonsai 2 9B, unified imports) | Pixels go to the model itself, independent of the Lens selection, when its vision memory fits |
| Text-only MLX, GGUF/llama.cpp, Core AI, Edge0, Apple Private Cloud | A local visual model describes the image; the selected model answers |
| API providers | The image goes to the provider when the model supports images |

Review findings, fixed here:

- I1: the Release (App Store) build failed to compile. `LocalModelRegistry.descriptor(for:)`
  is nonisolated but now called the main-actor `DownloadableModel.supportsCategory`. The
  category helpers only read immutable identity and on-disk metadata, so they are
  `nonisolated`.
- I2: build 75 ships without the bundled SmolVLM2 (the archive log reports
  `BundledVLM source not found … skipping`). A text-only model's image send therefore
  ended in "Image analysis unavailable" for anyone without a visual model. Assistant now
  offers to download the selected Lens model, or SmolVLM 2 500M (~520 MB) by default. The
  download starts only on tap, and the image stays attached.
- L2 (above) also applied here: after the description, the reload used to switch to the
  saved default and strand the composer.

Not covered: native pixel input for GGUF (projector lifetime and admission), Core AI and
Edge0 (no image encoders in this build). These still use the description handoff.

## Resolved in 2.0.1 (76)

- **iCloud sync removed.** Nothing ever called `CloudSyncService.syncNow()`, and
  no UI set `iCloudSyncEnabled`, but the listing, policy and guide advertised it.
  The service, its tombstones, the setting and their tests are deleted. Without
  the entitlement, touching `CKContainer(identifier:)` would raise. The CloudKit
  keys are gone from all five app entitlement files, and `verify_appstore.py`
  plus the sideload build now reject any iCloud entitlement. The privacy policy
  (now v8; users accept it once), repo privacy policy, user guide, delete
  confirmation (and its 6 translations) and developer docs no longer mention
  sync. 2.0.1 listing drafts for all 11 locales live in
  `AppStoreMetadata/localizations/version/2.1/`. The website sources are
  regenerated but not deployed.
- **A3:** opening a past chat, or starting a new one, selects its model without
  loading weights; the next send loads it (L1). A load or download already
  underway keeps the old switch path so it isn't cancelled, and the last of
  several quick selections wins.
- **A10:** "Search chats" also matches text in every user and assistant turn,
  through a host closure on `ODStore`, computed only while a query is active.

## Still open

- A5 is moot now that sync is gone. A11: the package catalog covers the six app
  languages; the listing has eleven.
- A9: benchmark run identity.
- Native pixel input for GGUF (projector lifetime and admission), Core AI and
  Edge0 (no image encoders in this build); these use the description handoff.

## Verification

| Check | Result |
| --- | --- |
| `scripts/validate_open_source.sh` | passed |
| `scripts/test_studio_policies.sh` | 18 passed (was failing before L9) |
| `scripts/test_minicpm_v47.sh` (includes titler host tests) | 64 passed; titler 9, 3 new for L8 |
| `scripts/test_memory_budgets.sh` | 140 passed |
| quantization, HF download cleanup, portable classifier, Edge0 cleanup scripts | passed |
| `scripts/tests/test_appstore_verification.py` | 32 passed |
| `xcodebuild build-for-testing`, Release, App Store settings, `generic/platform=iOS`, unsigned | succeeded (app and test bundle; no new warnings) |
| New `ConversationStoreFileSafetyTests` (L5, L6) | compiles in the device test bundle; runs on device only |

Do not run IOSLocalLLMTests on a phone that has real chats: existing
`StoredConversationTests` and `WipeKeychainTests` write to the app's real
container.
