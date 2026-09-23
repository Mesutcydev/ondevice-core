# Round 2 implementation — 2026-09-20

## Scope and baseline

This implements the latest eight-screen refinement request in the existing application. It preserves the first pass and the earlier API server requirement: one retained workbench, Create/Manage drawer groups, no bottom tabs, API server as a page, Mac bridge hidden.

Read the root agent guide, QA handoff, README, setup, contributing and architecture guidance before changing the active routes. Baseline build 44 was verified against `build/round2/baseline-source-hashes.json` (328 matching source fingerprints). Existing unrelated edits were retained. No storage migration, model weight changes, new dependency or inference-engine replacement was introduced.

Environment: Xcode 27.0 (27A5218g), app deployment iOS 27.0, OnDeviceUI package minimum iOS 26. The installed SDK declares `safeAreaBar` from iOS 26. This implementation uses coordinated `safeAreaInset` owners without changing deployment targets.

Active route: `ContentView` → `OnDeviceWorkbench` in `Packages/OnDeviceUI`. Host integrations remain in `ODBridge` and `WorkbenchSelectionObserver`. Simulator review uses `QA/NativeUI`, because production CoreAI is device-only. Screenshots contain explicitly review-only service fixtures.

## Implemented behavior

- **Camera ownership:** all AVCaptureSession configuration/start/stop and demand transitions are serialized on the capture queue. Permission completion only configures; it cannot reacquire a departed Lens screen. Background/foreground transitions preserve explicit demand. A selected image stops live capture. Merely retaining a hidden workspace no longer means retaining camera use.
- **Voice ownership:** session and turn operation IDs reject late recognition/generation callbacks. End invalidates ownership first, cancels startup/recognition/reply/playback work, stops owned audio objects and releases leases. Audio deactivation uses `notifyOthersOnDeactivation` only after the last tracked audio owner releases; failures enter diagnostics. Muting clears pending input and pauses/removes the recording input tap. Recognized text is accepted only by the current listening, unmuted session with actual capture running.
- **Diagnostics:** debug-only `sensor-ownership` events contain operation IDs and state, never frames, raw audio, prompts or transcripts. These are investigation hooks, not proof of physical cleanup.
- **Persistent voice:** one shared accessory appears on Chats, Chat, Lens, Voices, Image studio, Models, Device, API server and the open drawer. It describes the selected voice, actual session phase, capture/mute state and playback mute. Return and End are separate accessible actions. Hidden retained workspaces explicitly suppress their accessories. Full voice presentation suppresses the minimized bar.
- **Bottom geometry:** each page composes the accessory and its own primary controls under one inset. Lens pins the accessory above its scrollable controls; chat/image place it above the composer. No screen-height offsets or extra tab bar.
- **Conflicting operations:** chat submission, model replacement and image analysis/generation request confirmation while voice owns the runtime. Confirmed work awaits voice selection restoration before claiming the runtime. Engine browsing is harmless; selecting a replacement speech engine asks before ending voice.
- **Lens:** live Capture takes a retained still without analyzing. Photos also stages an image. The user reviews it, edits the preserved question/preset, then chooses Analyze. Retake/Change image, cancellation and existing result/history actions remain wired. Image pixels, selected model and prompt are captured per operation; stale results cannot overwrite the next image. Existing Ask/Translate/Scan/Solve are prompt presets, not promises of guaranteed OCR or other capabilities. FastVLM now receives the captured question through its existing question API.
- **Chats/drawer:** title and localized date share a line, with a secondary message snippet below; accessibility text reflows. Snippets are derived from existing content and remove Markdown decoration, including an image attachment label. Last activity ordering, IDs, user titles, rename/delete/pin/search and retained drafts remain intact. Chats uses a conversation symbol. Drawer search opens/focuses Chats; no duplicate Recents inventory was added.
- **Voices:** compact selected voice, count and language filter together, independent selection and 44-point Preview/Stop targets, reduced redundant row spacing. Filtering preserves the selection. An active conversation uses the shared return/end bar instead of a second Start action.
- **Active voice:** Voice options is a native toolbar menu; native route selection sits beside Output. Playback mute and microphone state remain separate. Status/controls use natural layout regions. Live input metering uses actual microphone levels when available and a static symbol under Reduce Motion.
- **Image studio:** the existing three prompts have short labels and compact rows. A nonempty different draft requires Keep draft/Replace confirmation. The composer remains editable before setup, with compatible image-model choices and a concise action row. Model installation does not trigger generation. Existing cancellation, failure recovery and export remain wired.
- **Models:** Installed explicitly means the download/import catalog. Core AI packs remain separately managed. Synthetic selected-runtime entries are excluded from that inventory count. Storage labels acknowledge model files and cache. Selection, installation and runtime phase remain independent. FastVLM installation uses its existing combined decoder/encoder check, rather than treating an unloaded installed model as absent.
- **Device:** friendly current-model name plus real state/execution replace four top-level rows; technical ID remains in a disclosure with selectable text. Runtime, Storage and Advanced tools remain native grouped destinations.
- **Composer:** existing geometry and behavior retained; the production microphone slot is wired to the existing dictation button. Dictation requests confirmation if it would replace an ongoing voice session. Drafts, attachments, send/stop and request-lifetime protection remain intact.

## Verification record

Final focused verification completed 2026-09-20 13:24-13:43 on both QA simulators (compact `D0EDAD87-10C5-4047-9963-2352D4370383`, large `5575B8F8-981C-4CBF-BD4C-29D2B8BB557A`):

- `xcodebuild test -project QA/NativeUI/NativeUIReview.xcodeproj -scheme NativeUIReview -parallel-testing-enabled NO -derivedDataPath build/round2/DerivedData -only-testing:HostContracts -only-testing:NativeUIFlows/APIServerWorkspaceTests -only-testing:NativeUIFlows/RoundTwoFlowTests/testSettingsKeepsOngoingSessionReachable -only-testing:NativeUIFlows/RoundTwoFlowTests/testMinimizedVoiceHasOneReturnAndEndOnEveryWorkspaceAndDrawer CODE_SIGNING_ALLOWED=NO` passed on both destinations: 5 UI tests each with 0 failures, plus 11 HostContracts swift-testing checks each. Result bundles: `Test-NativeUIReview-2026.09.20_13-30-55` (compact) and `Test-NativeUIReview-2026.09.20_13-34-52` (large).
- `-only-testing:NativeUIFlows/RoundTwoFlowTests/testSessionAccessoryStaysAboveEveryEditorKeyboard` passed on compact across six launches (composer/lens/image, each in standard and large-type+dark), bundle `Test-NativeUIReview-2026.09.20_13-41-01`. Recaptured keyboard screenshots live in `build/round2/after/402/RoundTwoScreenshots/session-keyboard-*.png`; the large-type captures show the session accessory with fully wrapped secondary text and End on its own row, no truncation or overlap, after the `fixedSize(horizontal: false, vertical: true)` sizing fix in `ODWorkspaceBottomBar`.
- The last standing failure, `APIServerWorkspaceTests.testPageNavigationRetainsDraftAndServerControls`, was a dismissal-contract defect. The test dismissed the model picker sheet with a fast `swipeDown()` flick, which does not drive iOS 27 interactive sheet dismissal under synthesized events, so the sheet kept covering `api.enabled`. The failure screenshot, extracted directly from the xcresult `Data` blobs because `xcresulttool export attachments` requires unsandboxed writes, showed the sheet still presented after five flicks. The QA fixture picker in `QA/NativeUI/HostStubs.swift` now mirrors the production picker's `NavigationStack` plus Done toolbar button (`picker.done`), and the test dismisses with a press-and-drag from the card top, which drives the real interactive dismissal (run log records `interactive sheet dismissal by drag: true`), falling back to Done only if a future platform stops honoring the drag. The test passed at 13:27 and inside both full-selection runs.
- Production Release build covering the `ODWorkspaceBottomBar` sizing fix: `xcodebuild build -workspace OnDeviceMax.xcworkspace -scheme OnDeviceMax -configuration Release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` ended `** BUILD SUCCEEDED **` at 2026-09-20 13:47 (pre-existing `AnalysisService` weak-capture warnings unchanged).

The first production Release build and QA test build passed; a further production Release build covering the `ODWorkspaceBottomBar` sizing fix is recorded at the end of this section. Repository hygiene passed. Focused new interaction tests passed after fixing hidden-workspace duplicate accessibility controls and draft-replacement confirmation presentation.

Matched baseline screenshots: `build/round2/before/402` and `build/round2/before/440`. Final screenshots: `build/round2/after/<width>/NativeUIReviewScreenshots` and `RoundTwoScreenshots`. The gallery and pair manifest are generated at `build/round2/screenshots.html` and `build/round2/screenshot-pairs.json`. Timestamps differ; fixtures, device widths, appearance and text sizes are otherwise matched.

## Physical release gate — still requires evidence

The latest device enumeration (`build/round2/physical-devices.json`) listed xoxo7, the paired iPhone 17 Pro Max, as **unavailable**. A reconnect request is pending. Simulator UI tests and successful builds do not verify real privacy indicators, microphone taps, Bluetooth routes, thermal/model admission, camera orientation or generation on installed model assets. Do not mark these acceptance conditions passed based on this report.

On a physical device running this revision:

1. Launch a Debug build; observe `com.mesutcydev.ondevicemax` / `sensor-ownership` events without logging any media or private text. Note the session operation IDs.
2. Open Lens, confirm actual camera use and system attribution; leave for Voices. Camera ownership should stop. Repeat during initial permission completion and by backgrounding/foregrounding after leaving Lens.
3. Preview two voices without starting a conversation. They must play independently and must not request or start microphone capture. Stop the sample.
4. Start voice; verify real input and a complete answer. Mute input, speak, and confirm no new transcription/submission. Unmute and confirm input resumes. Check playback mute separately from output route.
5. Minimize voice and visit Image studio, Models, Device, Chats, Chat, Lens, API server and the open drawer. Verify exactly one reachable Return/End bar. Check it with the keyboard visible and after scrolling to the final row.
6. Attempt an incompatible model/generation operation: cancel the confirmation and verify voice continues; confirm it and verify ownership ends before the replacement operation starts.
7. End voice while listening, loading, thinking and speaking. Verify no queued callback restarts capture/playback, and verify system attribution ceases once every legitimate media owner has released. Repeat with headphones/Bluetooth, an interruption, and an independent audio user; unrelated audio must not be deactivated.
8. Lens: capture a distinct still, change device orientation, then Analyze. Verify the answer uses the reviewed image and question. Retake/change image during cancellation; verify stale output cannot appear on the next image. Test denied camera, photo cancellation, missing model and model-load failure.
9. Image studio: edit a prompt before installing a compatible model; choose/download/cancel/return. Verify the draft survives and generation starts only after Create. Verify output review/export and failure/cancel recovery.
10. Compare Models, Device, Chat and Voice at the same moment; verify real selected/resident model state. Send short and multiline chat prompts to the installed Ornith model, cancel one reply, then retry. The earlier device inference stall must not be considered resolved without this runtime test.

Official references consulted: [privacy indicators](https://support.apple.com/en-gb/108331), [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [UI design tips](https://developer.apple.com/design/tips/), [safeAreaBar](https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:)), [safeAreaInset](https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)), [audio activation/deactivation](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:)), [AVCam](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app).

## Changed files

This list is scoped to Round 2 relative to the build-44 fingerprints; it is not the repository’s entire pre-existing dirty working tree. Generated Xcode files follow the existing XcodeGen setup.

- `IOSLocalLLM/ContentView.swift`
- `IOSLocalLLM/Views/WorkbenchSelectionObserver.swift`
- `IOSLocalLLM/Views/HomeView.swift`
- `IOSLocalLLM/Views/CodingAssistantView.swift`
- `IOSLocalLLM/Views/MicDictationButton.swift`
- `IOSLocalLLM/Views/VoiceModelPickerView.swift`
- `IOSLocalLLM/Views/VoiceConversationView.swift`
- `IOSLocalLLM/Views/ImageGenerationView.swift`
- `IOSLocalLLM/Services/VoiceConversationService.swift`
- `IOSLocalLLM/Services/ODBridge.swift`
- `IOSLocalLLM/Services/AnalysisService.swift`
- `IOSLocalLLM/Services/SpeechDictationService.swift`
- `IOSLocalLLM/Services/CameraService.swift`
- `IOSLocalLLM/Services/Voice/AudioPlaybackService.swift`
- `IOSLocalLLM/Services/Voice/VoiceService.swift`
- `IOSLocalLLM/Services/Voice/VoiceAudioSessionManager.swift`
- `IOSLocalLLM/Views/Bridge/LocalAPIServerView.swift`
- `IOSLocalLLM/Views/Voice/VoiceSettingsView.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/ODWorkbench.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Models/ODModels.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Models/ODPresentation.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/State/ODStore.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODChatView.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODVoiceLibraryView.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODModelsView.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODLensView.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODVoiceSessionView.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODConversationDrawer.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODImageStudioView.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODConversationsHome.swift`
- `IOSLocalLLM/Models/CaptureSessionDemand.swift`
- `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODWorkspaceBottomBar.swift`
- `Packages/OnDeviceUI/Example/OnDeviceUIDemo/OnDeviceUIDemoApp.swift`
- `QA/NativeUI/project.yml`
- `QA/NativeUI/HostStubs.swift`
- `QA/NativeUI/ReviewApp.swift`
- `QA/NativeUI/HostContracts/WorkbenchSelectionTests.swift`
- `QA/NativeUI/UITests/NativeUIFlows.swift`
- `QA/NativeUI/UITests/BriefPresentationMatrix.swift`
- `QA/NativeUI/UITests/APIServerWorkspaceTests.swift`
- `QA/NativeUI/UITests/RoundTwoFlowTests.swift`
- `Docs/ROUND2_IMPLEMENTATION.md`
- `Docs/QA_LOOP_HANDOFF.md`

The final source/file fingerprints are in `build/round2/changed-files.json` and `build/round2/final-source-hashes.json`.
