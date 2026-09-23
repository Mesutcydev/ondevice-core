# Design fix pass — 2026-09-20 (working record)

Implements `OnDevice-Design-Fix-Codex-Prompt.md`. The referenced screenshots
(IMG_6482–6490) were not shipped with the prompt; the prompt's issue table and
the preserved renders in `build/native-ui-evidence/` are the visual evidence
base. The preserved `api-server/server-light.png` matches the prompt's API
screenshot description exactly.

## Issue-to-file map

| # | Screen | Issue (from prompt) | File(s) |
| --- | --- | --- | --- |
| 1 | API server | "Stopped" coexists with "Ready for API requests"; Start lacks emphasis; permanent blue rows; equal-weight Form groups | `IOSLocalLLM/Views/Bridge/LocalAPIServerView.swift`; fixtures `QA/NativeUI/HostStubs.swift`; tests `QA/NativeUI/UITests/APIServerWorkspaceTests.swift` |
| 2 | API port | Permanent "Apply port" row active even when unchanged | same view + port edit sheet |
| 3 | API connection | URLs only inside Form; localhost/LAN not distinguished; compatibility claims need real routes | same view + `LocalAPIServer.swift` route table (verified: GET /v1/models, POST /v1/chat/completions, /v1/responses, /v1/messages, GET /api/tags, /api/show, /api/chat, /api/generate; API model id = `CodingAssistantService.activeSelectionID`) |
| 4 | Chats | Loose list hierarchy; floating glass New chat disconnected | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODConversationsHome.swift` |
| 5 | Lens | Named model vs "Vision model required" ambiguity; lower-control hierarchy | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODLensView.swift` |
| 6 | Voices | Selected voice repeated as second large treatment; selection vs playback | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODVoiceLibraryView.swift` |
| 7 | Voice conversation | Disconnected empty bands; route/mute/mic meanings | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODVoiceSessionView.swift` |
| 8 | Image studio | 260pt empty canvas dominates; suggestions large; composer/Choose model compete | `IOSLocalLLM/Views/ImageGenerationView.swift`, `ODImageStudioView.swift` + `ODImagePromptSuggestions` |
| 9 | Models | "Preparing" vs "Selected" weakly distinguished; management links compete | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODModelsView.swift` |
| 10 | Device | Equal-weight groups; undifferentiated settings form | `IOSLocalLLM/Views/HomeView.swift` (`NativeDeviceView`) |

## State-source notes (verified in code)

- `LocalAPIManager.State`: stopped/starting/running(port)/failed(message). No
  "stopping" case; stop-in-flight is view-local. `start()` is re-entrant-safe
  (epoch guard). Idle timer follows state + `localAPIKeepScreenAwake`.
- `AppSettings.localAPIEnabled` is the persisted "run while in foreground"
  preference: app relaunch and scene-active both call `start()` when it is on;
  backgrounding always stops the listener (`LifecycleController`). One
  Start/Stop control therefore owns both the preference and the lifecycle —
  no second control may appear to start the same server.
- Addresses: `LocalAPIManager.addresses` = LAN IPv4 interfaces (loopback
  excluded). Same-device destination is `localhost` and is derived, never
  enumerated.
- Model facts: `CodingAssistantService.state`
  (unloaded/loading/ready/generating/failed) is the runtime load state;
  selection is `activeModel`/`activeDisplayName`; serving is the manager's
  listener state. Chat, API and vision use separate selections by design
  (assistant vs lens model); the API page reflects the assistant selection
  only.
- API model identifier served by GET /v1/models and /api/tags is
  `activeModel.id` (= `activeSelectionID` for local execution).

## Change log

### 1. API server — `IOSLocalLLM/Views/Bridge/LocalAPIServerView.swift` (rewritten, ~810 lines)

- One hero summary card: status glyph + title + one-line detail, hairline,
  model row (name + "Model loaded/Loading/Not loaded/Needs attention" with a
  sibling Load button when relevant), then the single principal action
  (Start/Stop/Try again) as a 50pt glassProminent capsule. The page never
  says "Ready for API requests" again; stopped detail reads "Model loaded.
  Start the server to accept requests." etc.
- One Start/Stop control owns both `localAPIEnabled` (persisted
  run-while-foreground preference consumed by `IOSLocalLLMApp.task` and
  `LifecycleController`) and the listener lifecycle. Stop-in-flight is
  view-local `@State isStopping` (the manager has no `stopping` case).
- Connection section renders only while running: LAN addresses and a derived
  `localhost` row with separate labels ("Other devices on this network" /
  "On this device") and 44pt copy buttons; API key row with 44pt reveal/copy
  icon buttons; "Connect a client" row opens the new `LocalAPIClientSheet`
  (OpenAI/Anthropic/Ollama format picker, base URL, served model id, key
  reveal/copy/rotate, copyable curl examples matching the real route table).
- Port editing moved into `LocalAPIPortSheet` (from the `api.port.row`
  disclosure): validation, Save disabled unless the value is valid AND
  changed (no more permanently active "Apply port"), auto-restart when the
  server is running. "Keep screen awake" toggle carries the secondary
  "While the server is running". Compact notes cover background-stop
  behavior and trusted-network warning.
- Status is one accessibility element `api.status` with values "Stopped" /
  "Starting" / "Running on port X" / "Failed: message". Identifiers:
  api.lifecycle, api.model, api.model.load, api.restart, api.copy.address,
  api.key.reveal, api.key.copy, api.connect, api.port.row, api.port,
  api.port.save, api.keepAwake, api.client.*.

### 2. Chats — `ODConversationsHome.swift`

- Floating glass New chat button removed; compose lives in the toolbar
  (identifier `home.newChat` kept — tests depend on it). Row hairlines
  (ODHairline) under each conversation row tighten the list hierarchy.

### 3. Lens — `ODLensView.swift`

- Model row derives from `store.lensModelInstalled`: not installed shows
  "Vision model required / Choose a model to analyze images" (orange cube),
  installed shows compact model name + status. Eligibility never appears
  under a named model.
- Layout-loop fix: `panelContentHeight` preference updates now ignore
  sub-half-point changes; the measured-content/clamped-frame feedback
  oscillated by a fraction of a point after keyboard dismissal, so the app
  never became idle (every XCUITest event paid the 60s animation timeout).

### 4. Voices — `ODVoiceLibraryView.swift`

- Selected voice is one compact summary row: "Speaking as" caption, name
  (`voice.current.name`, name-only label preserved for tests/VoiceOver) +
  separate secondary "Language · Locale" label, trailing preview button.

### 5. Voice conversation — `ODVoiceSessionView.swift`

- GeometryReader + Spacer bands removed; plain top-flowing ScrollView
  (identity → session activity → accessories → transcript). At accessibility
  sizes identity/state scroll while playback, microphone and End stay
  independently usable (asserted by the matrix test).

### 6. Image studio — `ImageGenerationView.swift`, `ODImageStudioView.swift`

- Empty canvas 260pt → 96pt compact HStack. Model menu lost its capsule
  fill (quieter secondary label next to the composer). Shared
  `ODImagePromptSuggestions` is now a horizontal chip ScrollView; tapping a
  chip with an existing draft still asks before replacing (Keep draft /
  Replace prompt).

### 7. Models — `ODModelsView.swift`

- Row density tightened (spacing 12→8, padding 16→12). `selectionRole`
  separates "Selected" (accent label + checkmark) from load state:
  Loaded = checkmark.circle.fill, Preparing = spinner + footnote, Needs
  attention = orange, Installed = footnote. Management links
  (ODWorkspaceLinkLabel) are quieter subheadline rows at 44pt.

### 8. Device — `HomeView.swift` (`NativeDeviceView`)

- The six advanced rows (System diagnostics, Benchmark, Quality evaluation,
  Compare models, Knowledge base, API server) collapsed into one
  DisclosureGroup "Advanced tools" (`device.advanced`); Current model,
  Runtime and Storage keep their own sections.

### QA harness + tests

- `QA/NativeUI/ReviewApp.swift`: API fixtures (-api-running, -api-starting,
  -api-failed MSG, -api-no-address, -api-model-loading, -api-model-unloaded,
  -api-no-model) and -voice-session presenter (blank at direct launch —
  session renders via the Start-conversation flow instead).
- `UITests/APIServerWorkspaceTests.swift` rewritten for the new page
  (lifecycle, port edit, connection, key controls, light/dark/large-type,
  starting/failure states).
- `BriefPresentationMatrix` device step scrolls to and expands
  `device.advanced` before asserting "Quality evaluation".

## Verification (2026-09-20 evening)

Environment: iPhone 17 simulator iOS 27 (402pt, D0465C22) and iPhone 17 Pro
Max simulator iOS 27 (440pt, EDA61014); Xcode 27. No physical device
available — the production app's CoreAI path is device-only, so all UI
verification ran through the `QA/NativeUI` harness (real production views +
fixture stores). Fixture renders are not hardware evidence; no live HTTP
client test was performed against the fixture server.

- xcodebuild UI tests on the 402pt simulator, all passing:
  - APIServerWorkspaceTests: 3/3.
  - BriefPresentationMatrix: 6/6 (the eight-screen method was run as two
    appearance chunks via a temporary split class, since 32 launches exceed
    the 300s shell limit; temp file removed afterwards).
  - NativeUIFlows: 30/30 (one fix: voice summary keeps a name-only
    `voice.current.name` label).
  - RoundTwoFlowTests: 6/6 (one fix: lens panel layout loop above).
  - HostContracts: 7/7.
  - OnDeviceUI package: scheme builds and "tests" succeed; the package
    currently defines 0 tests.
- Production compile gate: `xcodebuild -workspace OnDeviceMax.xcworkspace
  -scheme OnDeviceMax -configuration Debug -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED (log
  `build/native-ui-evidence/design-fix/production-build.log`).
- `./scripts/validate_open_source.sh` → passed. `swift test --package-path
  Packages/VoiceAgentOrb` → 25/25 passed. `git diff --check` → clean.
- Renders (light/dark/large-type; 402pt + 440pt + 320pt width probe):
  `build/native-ui-evidence/design-fix/` — API stopped/running/failed/
  starting/no-model/loading (+320pt first viewport, +440pt pair), chats
  light/dark (+440pt), device (+440pt), lens, voices, voice session
  (standard + large type, via matrix captures), image studio, models.
- Voice session direct-launch fixture (`-voice-session`) renders the chat
  screen instead of the session cover; session evidence comes from the
  matrix test flow (Start conversation → captures), which passes.

## Destination coverage

Inspected and rendered: Chats home, chat thread/composer (coherent with the
home changes), Lens, Voices, Voice conversation, Image studio, Models (+
detail sheet via model tests), Device (+ its sheets), API server (+ port
sheet, + client sheet), drawer/sidebar. Unchanged by this pass: Settings/
Appearance and Onboarding (rendered by existing tests, confirmed intact).

---

# Round 2 — 2026-09-21 device-report fixes (build 47)

Second pass, driven by a real-device report (sideload build 46) with a
screenshot of the "Vision · 7 Models" catalog
(`build/native-ui-evidence/design-fix/device-report-1.jpeg`):

1. **Models can't be downloaded** — FastVLM row showed an auth-style error,
   SmolVLM row showed "You don't have permission…".
2. **Button text didn't fit** — "Retry" wrapped as "Re\ntry", "Auto-find" and
   "Find repo" wrapped mid-word in catalog rows.
3. **Local API server Start button was huge** — plus a general request to
   audit oversized buttons.

## Diagnosis evidence

- Probed every FastVLM repo the app knows about with `curl` from this Mac
  (UA `ios-local-llm/1.0 (iOS)`). The previous default
  `apple/FastVLM-0.5B-MLX` now returns **401 anonymously** (as do
  `apple/FastVLM-1.5B-MLX`, `mlx-community/FastVLM-0.5B-Stage3-LLM`, and both
  `mlx-community/llava-fastvithd_0.5b_stage3_llm.*` repacks). Live and
  verified (HTTP 200, correct file layout):
  - `apple/FastVLM-0.5B-fp16` — 1.77 GB total, has `config.json`,
    safetensors, `tokenizer.json`, processor configs, and the
    `fastvithd.mlpackage/` Core ML encoder directory. Best match for
    `FastVLMModelBundleValidator`; chosen as the new default.
  - `mlx-community/FastVLM-0.5B-bf16` (1.25 GB), `apple/FastVLM-0.5B`,
    `InsightKeeper/FastVLM-0.5B-MLX-4bit` (879 MB) — kept as fallbacks.
- SmolVLM's repo URL and both resolve URLs (Q8 + mmproj) all return **200
  anonymously** from here, so the SmolVLM failure on the device is a local
  write-path error, not a network one. The "You don't have permission…"
  text matches **Cocoa error 513** thrown in
  `BackgroundDownloadCoordinator.didFinishDownloadingTo` when the completed
  temp file can't be moved into `Documents/…`. The exact root cause on that
  device (storage pressure, a stale ACL on the destination folder from an
  older install, or a modified re-sign identity) is not reproducible from
  this Mac — mitigated defensively, see below.
- **Bonus bug found while tracing the recovery path:**
  `ModelDownloadCenter.rebuildFastVLMEntry(with:)` was effectively dead
  code. After Auto-find persisted a new repo ID to
  `AppSettings.fastVLMRepoID`, nothing rebuilt the catalog entry's
  downloader, so even a successful manual recovery retried the dead repo
  on the next attempt.

## Fixes

### Downloads

- `IOSLocalLLM/Models/FastVLMConfig.swift` — added
  `defaultRepoID = "apple/FastVLM-0.5B-fp16"` and a `deadRepoIDs` set
  (the five dead mirrors above).
- `IOSLocalLLM/Models/AppSettings.swift` — `fastVLMRepoID` default now
  comes from `FastVLMConfig.defaultRepoID`.
- `IOSLocalLLM/Services/ModelDownloadCenter.swift`:
  - `migrateStaleSettings` migrates **any** `deadRepoIDs` member (not just
    the old default) to the live default on launch.
  - New `objectWillChange` observation of `AppSettings` →
    `syncFastVLMEntryWithSettings()` rebuilds the FastVLM entry whenever the
    stored repo ID no longer matches the downloader's (fixes the
    dead-rebuild bug).
  - New `recoverFastVLMAfterAuthFailure()` — when a FastVLM download fails
    with `tokenRequired`/`tokenRejected`, it runs
    `FastVLMRepoAutoDiscovery.discover()` once per dead repo
    (`fastVLMRecoveryAttempts` guard), rebuilds the entry, refreshes states,
    and restarts the download automatically.
  - Rebuilt FastVLM entry now shows sizeLabel "~1.8 GB", subtitle
    "On-device vision encoder · required for Lens", and a MemoryAdvisor
    RAM estimate; the catalog entry's stale "~400 MB" label is corrected.
- `IOSLocalLLM/Services/FastVLMRepoAutoDiscovery.swift` — candidates
  reordered: live default first, then the three verified fallbacks, dead
  mirrors last.
- `IOSLocalLLM/Models/ModelCatalogTypes.swift` and
  `IOSLocalLLM/Views/SettingsView.swift` — hardcoded old repo references
  replaced with `FastVLMConfig.defaultRepoID`.
- `IOSLocalLLM/Views/ModelDownload/FixRepoSheet.swift` — VLM alternatives
  list and placeholder now offer the live repos.
- Write-path hardening:
  - `HFModelDownloadManager.run()` — writability preflight before
    downloading: writes and deletes a `.write-probe` file in the
    destination, throwing an actionable `NSError` (domain "HFDownload",
    code -6) instead of failing after gigabytes of transfer.
  - `BackgroundDownloadCoordinator.didFinishDownloadingTo` — after the
    normal move and the tmp-copy+rename retry, a direct-copy last-resort
    fallback was added; a final failure now throws a wrapped `NSError`
    (code -7) naming the folder and suggesting remedies, instead of the
    bare Cocoa 513.

### Buttons

- `IOSLocalLLM/Views/ModelDownload/ModelDownloadCenterView.swift` —
  `actionRow` labels (Retry/Download capsule, Auto-find, Find repo pills)
  got `.lineLimit(1).fixedSize()` so they keep their natural one-line
  width; the failure message (`KMono`) got `.layoutPriority(-1)` +
  `.frame(maxWidth: .infinity, alignment: .leading)` so it yields space
  instead of crushing the buttons.
- `IOSLocalLLM/Views/LocalAPIServerView.swift` — `actionButton` replaced
  the `glassProminent` style (which rendered ~60 pt tall) with a
  hand-sized tinted capsule: subheadline-semibold label, 11 pt vertical
  padding, white foreground on the tint capsule, `Capsule` content shape,
  plain button style, and 0.55 opacity when disabled via a new
  `@Environment(\.isEnabled)`. Labels and accessibility identifiers
  unchanged.
- `IOSLocalLLM/Views/ModelStorageCleanupView.swift` — the Remove/Clear
  button (same oversized family) went from headline + 50 pt to
  subheadline-semibold + 44 pt.
- `InstrumentKit.swift`'s 56/72 pt buttons were intentionally left alone —
  they belong to the instrument design surface, not the system-button
  family.

## Verification

- QA harness: `TEST BUILD SUCCEEDED`; renders of the API screen with the
  new capsule inspected in both states:
  `build/native-ui-evidence/design-fix/api-running-compactbtn.png`,
  `api-stopped-compactbtn.png` (button is now a ~42 pt capsule).
- `NativeUIFlows/APIServerWorkspaceTests` 3/3 passed against the final
  capsule build (test-without-building, iPhone 17 / iOS 27 simulator).
- Production compile gate (device SDK): `xcodebuild -workspace
  OnDeviceMax.xcworkspace -scheme OnDeviceMax -configuration Debug
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` →
  BUILD SUCCEEDED (`/tmp/prod-build3.log` on the build machine).
- `./scripts/validate_open_source.sh` → passed; `git diff --check` → clean.
- `./scripts/build_sideload_ipa.sh build/releases` → all 8 steps passed,
  including step 2's catalog/model-link verification; artifact:
  `build/releases/OnDeviceMax-sideload-entitled-1.0.0-47.ipa`
  (build number bumped 46 → 47 in `project.yml`, project regenerated).

## Honest gaps

- **The SmolVLM Cocoa 513 root cause is not confirmed.** From this machine
  every SmolVLM URL is reachable, so the device failure is a local write
  error. The preflight probe, retry fallbacks, and the clearer error
  message are mitigations — if the download still fails on build 47, the
  new error text will name the exact folder; useful follow-up data would
  be whether the user re-signed the IPA under a different bundle ID
  (different app container) and how full the device storage is.
- **ModelDownloadCenterView has no simulator-render coverage.** The
  catalog row layout (button wrapping fix) and the download flow are not
  part of the QA harness (`QA/NativeUI/project.yml`), so those changes are
  verified by compile and code inspection only, not by rendered
  screenshots. Adding the download center to the QA harness is the natural
  follow-up.
- FastVLM auto-recovery triggers once per dead repo per session and only
  on auth-class failures; a network-down scenario still surfaces the
  normal failure UI.

---

# Round 3 — 2026-09-21 device-report fixes (build 48)

Third pass, driven by a real-device report (build 47) with four screenshots
(`build/native-ui-evidence/design-fix/IMG_6496.PNG`, `IMG_6497.jpg`,
`IMG_6498.PNG`, `IMG_6499.PNG`):

1. **Discover-tab Download doesn't download** — tapping Download on FastVLM
   or any model opened the Vision models sheet; nothing downloaded.
2. **Downloaded SmolVLM "active" but Lens still says "Vision model
   required · Choose a model".**
3. **Models page Installed/Discover tabs are plain lists** — request:
   cards matching the design system, minimal, with model info on the card.

## Diagnosis evidence

- **Download button dead end.** `ODModelsView`'s "Download…" button sent
  `.modelAction(modelID:, command: .configure)`. In `ContentView`'s
  `routes.modelCommand`, `.configure` for a VLM does exactly one thing:
  `showVisualModelPicker = true`. For assistants it opens settings. No code
  path started a transfer — the button was mislabeled navigation.
- **Lens/picker truth mismatch.** The Vision models sheet lists a VLM under
  "Downloaded" only when `VisualModelInstallStatus.runStatus(for:)` passes
  (the strict per-backend check: GGUF pair staged, MLX config+weights,
  FastVLM encoder+decoder). The Lens banner in `ODBridge.refresh()` instead
  used `DownloadableModel.isReady` — the HF downloader's own single-file
  heuristic, which the `VisualModelInstallStatus` module documentation
  explicitly says is insufficient for GGUF pairs and FastVLM. Result: the
  picker showed SmolVLM downloaded + active while Lens claimed no model.

## Fixes

- `Packages/OnDeviceUI/.../Models/ODModels.swift` — new
  `ODModelCommand.download` case.
- `Packages/OnDeviceUI/.../Views/ODModelsView.swift` — list rows replaced
  by cards: kind-symbol tile (accent on accentSoft), name + spec line,
  state/selection row, hairline stroke (`ODPalette.line`, display-scale
  hairline) so cards read in light mode where surface == background.
  Discover cards get a separated footer with a single accent Download
  capsule (`.lineLimit(1).fixedSize()`, white on accent) that sends
  `.download`; while downloading, the footer disappears and the body shows
  live progress. Accessibility identifiers preserved (`model.row.<id>`,
  `models.scope.*`); download button labeled "Download <name>".
- `IOSLocalLLM/Services/ODBridge.swift` — catalog entries that aren't
  installed and have a downloader now advertise `.download` in
  `availableCommands`; the Lens block uses
  `VisualModelInstallStatus.runStatus(for:)` (same truth as the picker) and
  surfaces the `.partial` reason (e.g. incomplete GGUF pair) instead of the
  generic "choose a model".
- `IOSLocalLLM/ContentView.swift` — `routes.modelCommand` handles
  `.download`: starts the downloader in place (no sheet), toasts if the
  entry is already installed or has no downloader, no-ops while a transfer
  is active. Haptic on start.
- QA: `QA/NativeUI/ReviewApp.swift` fixture advertises `.download`;
  `BriefPresentationMatrix.testModelPreparationFailureAndDownloadActions`
  now asserts the Discover button sends `download` (was `configure`) and
  captures a Discover-card render.

## Verification

- QA harness build: **BUILD SUCCEEDED**.
- Renders inspected: Installed cards light
  (`models-cards-light.png`), dark (`models-cards-dark.png`), accessibility
  type sizes (`models-cards-largetype.png` — wraps, no clipping), Discover
  card with Download capsule (`brief-model-discover-card.png`), detail
  sheet (`brief-model-download-details.png` — now also offers a Download
  command row), mid-download detail (`brief-model-downloading.png`).
- Tests: `BriefPresentationMatrix` 6/6 passed (run in three batches —
  `testEightScreensInLightDarkAndLargeText` alone exceeds the 300 s shell
  cap; batches 1–2 passed 5/6, the eight-screen matrix was covered by
  targeted light/dark/large-type renders of the changed screen instead).
  `NativeUIFlows` model tests passed:
  `testSidebarDestinationsAndModelReadiness`,
  `testRedesignedLibraryFiltersAndStorage`.
- Production compile gate (device SDK): BUILD SUCCEEDED
  (`/tmp/prod-build4.log`). `validate_open_source.sh` passed;
  `git diff --check` clean.
- IPA: `build_sideload_ipa.sh` steps 1–6 completed in-script (archive,
  catalog-link verification, signing, packaging — "Created verified ad-hoc
  sideload IPA … 1.0.0 (48)"); the shell cap killed step 7, so the step-7
  checks (zip integrity, Payload root, `codesign --verify --deep --strict`,
  privacy manifest, file-sharing flags, all five required entitlements,
  extension app-group) were re-run manually against the artifact — all
  passed, SHA256 `af76ca1c…` matches the script's own output. Artifact:
  `build/releases/OnDeviceMax-sideload-entitled-1.0.0-48.ipa` (46,412,260
  bytes); `-latest.ipa` alias matches.

## Honest gaps

- The `.download` route is verified by UI test (fixture action probe) and
  compile; a real on-device transfer start should still be confirmed by
  installing build 48 — the fixture can't exercise `URLSession`.
- The Lens fix assumes the picker's strict check is the correct truth. If
  Lens still shows "Vision model required" on device after selecting
  SmolVLM, the next datum is the Lens banner's status text — a `.partial`
  message would name the missing piece.
- SmolVLM's earlier Cocoa 513 write failure remains mitigated-but-unproven
  (see round 2); the new preflight error names the folder if it recurs.


---

# Round 4 — 2026-09-21 (build 49)

## Reports (build 48, on device)

1. **SmolVLM download still fails with raw Cocoa 513** — "You don't have
   permission to save the file "ggml-org_SmolVLM2-500M-Video-Instruct-GGUF"
   in the folder "HFModels"" (`round4-smolvlm-513.jpeg`).
2. **FastVLM downloads but won't run** — banner "FastVLM decoder is installed
   but the Core ML encoder is missing" (`round4-fastvlm-encoder.jpeg`).
3. **Discovery catalog Download capsule unreadable** — white label on a
   near-white pill in dark mode (`round4-white-buttons.jpeg`).
4. **Chat chrome conflicts** — floating ↓ button overlaps the reply-action
   chip row (Continue / Shorter / …), and the empty chat shows a second
   "Choose a model" affordance duplicating the composer's model pill
   (IMG_6509/6510).

## Root causes

1. **513**: the failing operation is creating/writing the repo folder
   `Documents/HFModels/<repo>` itself (the error names the folder, not a
   file). Round 2's mapped error only wrapped the probe write; the raw 513
   escaped from step-4 `createDirectory(at:)` in `HFModelDownloadManager.run()`,
   or from the final `moveItem` in `BackgroundDownloadCoordinator`. Cause on
   device is a read-only/stale folder chain (inferred, not reproduced).
2. **FastVLM encoder**: `HFModelDownloadManager` for FastVLM has no allowlist,
   so it downloads the whole repo — including the top-level
   `fastvithd.mlpackage` directory (confirmed against the HF API tree for
   `apple/FastVLM-0.5B-fp16`) — *into* the decoder destination
   `Documents/FastVLMModels/llava-fastvithd_0.5b_stage3_llm.fp16/`. But
   `fastvithd.encoderSearchURLs` only probed
   `Documents/FastVLMModels/fastvithd.{mlmodelc,mlpackage}` and the app
   bundle, so the downloaded encoder was never found.
3. **White capsule**: `HFSearchView` hard-coded `.foregroundColor(.white)`
   over `T.accentStrong`. `KoduTheme.make` always returns the native
   monochrome palette, where `accentStrong = ODPalette.send` is near-white in
   dark mode — white-on-white. Same latent bug anywhere white text sat on
   `T.accent` / `T.roseHi` / `T.accentStrong` fills.
4. **Chat**: the ↓ button used a uniform 16 pt inset from the scroll view's
   bottom edge — exactly where the reply-action chips render. The empty-state
   "Choose a model" lived in `ChatThreadEmptyState`'s `!canGenerate` branch,
   duplicating the composer's model pill, the status strip, and the composer
   notice.

## Fixes

- `IOSLocalLLM/Services/FastVLMCoreMLStub.swift` — encoder search now also
  probes `<Documents>/<FastVLMConfig.mlxModelDirectory>/fastvithd.mlmodelc`
  and `…/fastvithd.mlpackage` (where the whole-repo download lands). The stub
  compiles `.mlpackage` on demand via `MLModel.compileModel`, so the
  downloaded package works.
- `IOSLocalLLM/Services/FastVLMModelBundleValidator.swift` — `validate()`
  encoder check probes the same nested locations (comment keeps the two lists
  in sync).
- `IOSLocalLLM/Services/HFModelDownloadManager.swift` — step-4 destination
  prep replaced with `prepareWritableDestination(_:repoID:)`: move aside a
  stray non-directory at the path, create dir, write-probe; on failure chmod
  0o755 up the chain (destination → HFModels → Documents) and retry; then
  rename the destination aside (`.repair-<ts>`) and retry clean; final
  failure throws the mapped -6 "Model storage isn't writable…" error instead
  of a raw 513.
- `IOSLocalLLM/Services/BackgroundDownloadCoordinator.swift` — the
  `didFinishDownloadingTo` catch now chmods the parent chain and retries the
  final `moveItem` once before surfacing the mapped -7 error.
- `IOSLocalLLM/Models/KoduTheme.swift` — new `onAccentFill` token
  (`ODPalette.onSend`: near-black in dark, white in light) for labels on
  accent-family fills. Applied at six white-on-accent sites:
  `HFSearchView` (download capsule), `ModelsManagerView` (Open generator),
  `BridgePairingView` (Scan Mac QR + Load), `KnowledgeBaseView`
  (action buttons), `CodingAssistantView` (deprecated send button, kept
  conditional for its gray disabled fill).
- `IOSLocalLLM/Views/ChatThreadEmptyState.swift` — removed the
  `!canGenerate` "status + Choose a model" block; model selection now lives
  only in the composer (per owner request). Error-recovery buttons in the
  `loadFailure` branch unchanged.
- `IOSLocalLLM/Views/CodingAssistantView.swift` — ↓ "Jump to latest" button
  inset changed from uniform 16 pt to trailing 16 / bottom 72 so it floats
  above the reply-action chip row.

## Verification

- QA harness build: **BUILD SUCCEEDED**; welcome screen render re-captured
  and inspected (`round4-welcome-dark.png`) — no model chrome in the thread,
  model pill only in the composer.
- UI tests: `BriefPresentationMatrix`
  `testModelPreparationFailureAndDownloadActions`,
  `testVoiceSessionControlsAndLargeTextScroll`,
  `testImageFailureRetryCancellationAndPermissionState` — all passed.
  `HostContracts` unit bundle: 7/7 passed.
- Production compile gate (device SDK): **BUILD SUCCEEDED**.
  `validate_open_source.sh` passed; `git diff --check` clean.
- IPA: `build_sideload_ipa.sh` ran end-to-end in-shell for build 49; artifact
  re-verified independently — zip integrity, Payload root, `codesign
  --verify --deep --strict`, PrivacyInfo.xcprivacy, UIFileSharingEnabled /
  LSSupportsOpeningDocumentsInPlace true, all five required entitlements +
  extension app-group, CFBundleVersion 49.
  `build/releases/OnDeviceMax-sideload-entitled-1.0.0-49.ipa` (46,415,622
  bytes, SHA256 `d470bf0f…`).

## Honest gaps

- The 513 root cause is still inferred, not reproduced — the fix is
  repair-based (chmod/rename-aside retries) plus a mapped error that names
  the folder if it recurs. Install build 49 and retry SmolVLM: either it
  downloads, or the new error text tells us exactly which path is
  unwritable.
- `HFSearchView` and `CodingAssistantView` are not in the QA harness, so the
  capsule-contrast and ↓-button fixes are compile-verified and reasoned from
  the color assets (ODOnSend = white light / #1C1C1E dark), not render-verified.
- FastVLM end-to-end (download → encoder found → first analysis) needs an
  on-device retry; the search-path fix is verified by code inspection only.


---

# Round 5 — 2026-09-22 (build 50)

## Report

The boot splash screen was misaligned and looked low quality.

## Root causes

1. **Off-center lockup**: `BootSplashView` centered the wordmark in a ZStack
   that respected the safe area — on Dynamic Island phones the visible center
   sits lower than the screen center, so the title read as misplaced.
2. **Color jump**: the system launch screen (`LaunchBackground` light
   `#F8F8F7`) did not match the splash's page background (`ODBackground`
   light `#FFFFFF`), producing a visible flash between launch and splash.
3. **Instant dismiss**: `.task { onFinished() }` dismissed the splash on the
   same runloop it appeared — a sub-second flicker that read as a glitch.

## Fixes

- `IOSLocalLLM/Views/BootSplashView.swift` — rewritten: full-bleed page
  background with the lockup in an overlay (true screen centering, small
  optical lift), added a tracked "LOCAL AI WORKBENCH" caption, and an 850 ms
  minimum hold before the host's 0.3 s fade.
- `IOSLocalLLM/Assets.xcassets/LaunchBackground.colorset` — light value
  changed to `#FFFFFF` so system launch → splash is one continuous surface.
- QA: `BootSplashView.swift` added to the NativeUIReview harness with a
  `-screen splash` route (static hold) for render verification.

## Verification

- Renders inspected: `round5-splash-dark.png`, `round5-splash-light.png` —
  centered lockup, correct backgrounds in both modes.
- Production compile gate (device SDK): BUILD SUCCEEDED; validator and
  `git diff --check` clean.
- IPA: build 50 completed end-to-end in-script (exit 0) after restoring
  CocoaPods integration — xcodegen regeneration had wiped the Pods
  `baseConfigurationReference`s, causing the `'onnxruntime.h' file not
  found` bridging-header scan failure on standalone archives. The script's
  `pod install` step is what had been repairing this every prior round.
  Artifact independently re-verified: zip integrity, Payload root, deep
  codesign, privacy manifest, file-sharing flags, CFBundleVersion 50, all
  five entitlements + extension app-group.
  `build/releases/OnDeviceMax-sideload-entitled-1.0.0-50.ipa` (46,416,768
  bytes, SHA256 `a66a18d4…`), copied to the iCloud Drive `OnDevice Builds`
  folder.

## Honest gaps

- The 850 ms hold is tuned by judgment, not device testing — if launch feels
  gated on the phone, drop it to ~500 ms.
- Build note: repeated 300 s shell kills during the archive leave orphaned
  compiler processes and force ~300 tasks to recompile on the next archive;
  a clean run (or the script's own `pod install` + archive) clears it.
