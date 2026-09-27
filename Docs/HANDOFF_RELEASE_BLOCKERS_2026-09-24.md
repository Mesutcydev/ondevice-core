# Handoff: OnDeviceMax release blockers (2026-09-24, late)

Stopped at a safe point: investigation of the blockers below is done. No code
has been changed for them yet. Everything listed under "Already done" is in the
working tree, **uncommitted**.

## Already done this session

- **Folder import (build 64, published).** Changed files:
  - `IOSLocalLLM/Views/LocalModelImportPicker.swift` (new)
  - `IOSLocalLLM/Services/LocalModelImportService.swift`
  - `IOSLocalLLM/Services/CoreAIModelStore.swift` (`resolvePackRoot` is now internal; `importModel` returns the manifest)
  - `ContentView.swift`, `ModelsManagerView.swift`, `AssistantModelPickerView.swift`

  What it does:
  - Separate pickers: folders use `[.folder, .directory]` opened in place; files use `[.data]` with `asCopy: true`.
  - The Import model dialog lists model folders and GGUF files found in Documents ("On My iPhone › OnDevice Max"). Importing one moves it, but only when the import uses the whole source.
  - Core AI pack folders are routed to `CoreAIModelStore`.
- **Other fixes** (in `ModelDownloadCenter.swift`, `WipeAllDataService.swift`, `HFModelDownloadManager.swift`):
  - Restarting no longer renames imports to `local_X`, gives them a broken Hugging Face link, or loses their subtitle.
  - Wipe now also removes `Edge0Models` and `WhisperModels`.
  - Updated stale storage copy.
- **QA host:**
  - `QA/NativeUI/HostStubs.swift` stubs `documentsCandidates`.
  - `QA/NativeUI/UITests/NativeUIFlows.swift`: the Files test handles Files reopening at its last location, and a new test covers the Documents list. Both pass on sim `EDA61014-…`.
- **The same port in `~/Desktop/OnDeviceCoreAIStudio`** (`main`, uncommitted):
  - Picker code is inside `LocalModelImportService.swift`; no new file.
  - The duplicate import sheet and alerts in `ModelsManagerView.installedSection` are removed.
- **Published:**
  - GitHub `Mesutcydev/ondevice-core` releases `ondevice-max-1.0.0-64` and `ondevice-core-1.0.0-61`.
  - ondevice.fun links updated (site commit `aa9301b`).
  - Source for these builds is not committed or pushed. The Core release tag points at the build-60 source on `main`.

## Open blockers (user report with screenshots)

### 1. Files picker fails on ForgeSign installs (works on AltStore)
Findings:
- Web: iOS breaks the document picker when the signed `application-identifier` is invalid, e.g. a literal `TEAMID.*` copied from a wildcard profile. See [iOS App Signer PR #163](https://github.com/DanTheMan827/ios-app-signer/pull/163), [UTM #6989](https://github.com/utmapp/UTM/issues/6989) and [Feather PR #723](https://github.com/claration/feather/pull/723).
- Feather PR #723 also flags a doubled-prefix bug for partial wildcards: `TEAM.com.x.*` + bundle `com.x.app` becomes `TEAM.com.x.com.x.app`.
- ForgeSign Mobile (`~/Desktop/signman/ForgeSignMobile`, v2.6) expands `TEAMID.*` in `vendor/zsign/archo.cpp` `FSExpandWildcardAppId`. It has the same doubled-prefix bug for partial wildcards: it keeps `value.dropLast(1)` and appends the bundle ID. It also signs extensions with the profile entitlements.
- Desktop ForgeSign (`~/Desktop/signman/ForgeSign`) hasn't been used since Aug 4. Its history shows the user signs with a distribution cert plus a device-registered explicit profile, and the bundle ID is rewritten (e.g. `app.rose2136.zenith1511`).
- The OnDeviceLAS investigation (`LocalModelDocumentPickerSession.swift`, `LASAppIdentity.swift`) concluded that open-in-place folder grants fail on every re-signed install even with a concrete identity. Copy-mode picks work. ForgeSign Mobile's own picker was fixed the same way (README: 1.5 unfiltered picker, 1.7 `.import` mode).

Recommended app fix (not started):
- Add a **multi-file, copy-mode import**: `UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)` with `allowsMultipleSelection = true`, labelled e.g. "Choose model files in Files". The user opens the model folder, taps Select All, then Open.
- Rebuild the folder: create `HFModels/local_<name>`, move each picked tmp file into it, then run the existing validation and registration. Split `importModel(from:)` so the copy step accepts `[URL]`.
- This works because MLX and Edge0 folders are flat. Edge0 35B = `config.json`, `generation_config.json`, `tokenizer*.json`, `chat_template.jinja`, `model.safetensors.index.json`, `lora_edge0_35b.safetensors`, and shards; about 19.6 GB.
- Keep the folder picker (AltStore/App Store) and the Documents list.

Recommended signer fix (ask the user first; it's their other product):
- Fix the partial-wildcard expansion in `FSExpandWildcardAppId`: replace the whole pattern with `<prefix>.<bundleID>`, where prefix is the first component.
- Verify real output with `codesign -d --entitlements :- Payload/*.app` on a ForgeSign-signed OnDeviceMax IPA.

### 2. Imported Edge0 35B shows as a vision model, not in Assistant
- The pinned `config.json` has `vision_config`, `image_token_id` and `Qwen3_5MoeForConditionalGeneration`. `LocalModelRegistry.category(in:)` (`Models/ModelCatalogTypes.swift` ~L652) therefore returns `.vlm`.
- `Edge0ModelFamily.resolve` only accepts the exact curated repo ID, so a `local/…` import can never get runtime `.edge0MLX`.

Plan:
- In `LocalModelImportService` after the copy: if `Edge0_35BModelArtifacts.validateInstall(directory:)` passes (metadata-only, cheap), or `Edge0ModelArtifacts.validate(directory:)` passes for 8B, then:
  - adopt the folder into the curated preset: move it to that `DownloadableModel`'s `downloader.destination`, cancelling or removing any partial first;
  - refuse if the preset is already ready;
  - call `checkIfReady()` and return the preset's ID.
- Migrate existing `HFModels/local_*` Edge0 imports the same way during `scanCustomDownloads`.
- Make `category(in:)` return `.assistant` when `lora_edge0_*` or `prerouter_edge0_*` files are present.
- Clear `AppSettings.cameraVisualModelID` if it points at the migrated local ID.

### 3. Lens crashes with that model selected
- Not reproduced; no crash log is available.
- The paired phone "xoxo7" (`9FDBC7DA-…`, `xcrun devicectl device copy from --domain-type systemCrashLogs`) has no OnDeviceMax crashes today, so the test phone is a different one.
- `LensInferenceLoop.switchTo` preflight should refuse a 19.6 GB model safely. `stagedDirectory` resolves `HFModels/local_<name>`.
- Fixing #2 removes the model from Lens. Get the `.ips` from the user (Settings → Privacy → Analytics Data → OnDeviceMax-…) to confirm.

### 4. "Browse Models" in the Assistant chat-model sheet crashes (new)
- The path is `AssistantModelPickerView.availablePickerContent` → `dismiss()` + `AppBridge.requestTab(.models)` → `ContentView.applyRequestedTab` → Models tab.
- Prime suspect: `Packages/OnDeviceUI/.../ODModelsView.swift:513`, `Text("\(Int((progress * 100).rounded()))%")`. This traps if progress is NaN or infinite; check `DownloadableModel.progress` when total bytes are 0, and `ODBridge` `downloadProgress`.
- Guard with `progress.isFinite`, then clamp to 0...1. Also check for duplicate `ODModel.id`s in `store.models` (`matchedTransitionSource`).

### 5. Onboarding button sizing
Make these full-width with one shared height:
- `IOSLocalLLM/Views/Legal/LegalAcceptanceView.swift:49` ("Agree and continue", currently a small pill inside a card)
- `IOSLocalLLM/Views/Legal/LegalDocumentView.swift:96` ("Scroll to the end…" vs "I have read this" change width)

Use `.frame(maxWidth: .infinity, minHeight: 50)` on the label and the same button style for both states.

## How to build, verify and release
- **Compile gate:**
  ```
  xcodebuild build -workspace OnDeviceMax.xcworkspace -scheme OnDeviceMax -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/model-redesign-derived CODE_SIGNING_ALLOWED=NO
  ```
  Keep disk use low; the Mac ran out of space earlier.
- **Pods:** if `Pods/` is missing, run `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install` first.
- **IPA:**
  1. Bump `CURRENT_PROJECT_VERSION` in `project.yml` (2 places; now 64, so next is 65).
  2. Run `LANG=en_US.UTF-8 bash scripts/build_sideload_ipa.sh "$PWD/build/releases"`.
- **UI check:** the QA/NativeUI review host (see its README). argent taps don't register there; use XCTest.
- **Release and site:** follow the pattern in the user's memory (`ondevice-fun-website.md`). Ask before publishing again.
