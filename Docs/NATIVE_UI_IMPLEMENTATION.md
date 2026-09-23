> Current navigation: the user's later Codex iOS screenshots replace the previous tab shell with a conversation home and leading sidebar. See [sidebar implementation](SIDEBAR_NAVIGATION_2026-09-19.md). The historical validation results below describe earlier builds.

> Build 39 follow-up: [device screenshot audit](DEVICE_SCREENSHOT_POLISH_2026-09-19.md) and [Lens lifecycle regression](LENS_CAMERA_FIX_2026-09-19.md).

Latest follow-up: [Home, Models and Appearance — build 40](HOME_MODELS_APPEARANCE_REDESIGN_2026-09-19.md). This replaces the initial layouts for those screens and restores true OLED appearance.

# Current native design integration — 19 September 2026

The implementation uses the supplied `/Users/m/Downloads/OnDeviceNativeUI` package, its design brief, layout equations and the user's integration prompt. These supersede the earlier Instrument design and historical QA notes. The production app uses this presentation through `ContentView` and `ODBridge`; the demo is only a verification host.

**Status:** presentation integration is implemented and the production target builds. Simulator interaction and persistence checks pass. This is not a claim that every production operation has passed on hardware: real inference, camera, microphone, speaker and downloaded-model flows still require device acceptance below.

**Physical launch blocker:** a paired iPhone 14 Pro running iOS 27 became available. Building for it with the existing configuration failed because Xcode requires a development team for both `IOSLocalLLM` and `IOSLocalLLMShareExtension`. No production identity, signing settings, entitlements, installed app or container were changed to bypass that requirement. The team-selection question is pending.

## Follow-up repairs

- Each accepted chat request captures its conversation, model, request ID, draft revision, exact text and stable attachment IDs before asynchronous preparation. Web, document, image, Mac-context, tool and generation callbacks check ownership before publishing. A cancelled request cannot restart generation or append output into another conversation.
- Accepted attachment payloads come from the immutable snapshot. Clearing removes only that submission's references. When preparation fails or is stopped after newer text was entered, the original is saved in that conversation's **Unsent drafts** menu. Restoring it preserves the displaced draft; both survive the existing persistence format.
- Image cancellation keeps admission closed until both generation and GPU cleanup have drained. Stale progress/completion cannot replace the current result or release a newer task. Each completed image gets its own protected cache file and captured prompt/model; sharing uses that real file. PNG writing and display decoding run outside the main rendering path.
- Added the real Lens Stop route, gated host operations until routes are installed, and retained model readiness as separate from selection/installation.
- Settings model labels now wrap instead of using fixed-height animated marquees. Chat scroll transitions honor Reduce Motion, and the decorative voice activity mark pauses when the scene is inactive.
- Measured the shared composer at 320, 375, 393 and 430 points: writing width matches `W − 72`, action targets remain at least 44 points, and the full accessible model value survives visual truncation. Turkish/multiline text survives menu presentation and deliberate refocusing.

## Important implementation files

- [ContentView](../IOSLocalLLM/ContentView.swift) and [ODBridge](../IOSLocalLLM/Services/ODBridge.swift): production navigation, service snapshots and action routing.
- [ODComposer](../Packages/OnDeviceUI/Sources/OnDeviceUI/Components/ODComposer.swift) and [ODTheme](../Packages/OnDeviceUI/Sources/OnDeviceUI/Theme/ODTheme.swift): shared measured layout and current design tokens.
- [CodingAssistantView](../IOSLocalLLM/Views/CodingAssistantView.swift), [ConversationStore](../IOSLocalLLM/Models/ConversationStore.swift) and [PresentationRequestLifetime](../IOSLocalLLM/Models/PresentationRequestLifetime.swift): rich transcript, request ownership, persistent drafts and recovery.
- [ImageGenerationService](../IOSLocalLLM/Services/ImageGenerationService.swift) and [ImageGenerationView](../IOSLocalLLM/Views/ImageGenerationView.swift): cancellation draining, captured result identity, background image preparation and actual-file sharing.
- [NativeUI QA](../QA/NativeUI/README.md): isolated simulator host, focused regression tests and reproduction commands.

## Presentation and connected operations

| Area | Current implementation and connection |
| --- | --- |
| Shell | `OnDeviceWorkbench` owns the real Chat / Lens / Voice / Models `TabView`, Chat first. Native navigation, tabs and glass controls retain OS geometry. No root tint or hand-built tab bar. The drawer opens existing conversations and secondary Image studio, Device and Settings destinations. |
| Chat | The existing rich Markdown, code, media, search and message actions remain in `CodingAssistantView`. User messages use the shared neutral, right-aligned bubble layout; assistant output stays on the canvas. |
| Composer | Shared `ODComposer`: page inset 20, radius 24, 112-point lower bound before attachments, growing multiline field, metadata strip, plain add/model controls and separate supported dictation and Send/Stop. Return inserts a newline. Accessibility text moves the model menu above the action row. Keyboard dismissal stays at the leading edge of the native accessory. |
| Draft ownership | The host snapshots exact text and stable attachment IDs; only accepted matching drafts clear. Rejection retains the draft. Pending web/image preparation cancels through existing services and ignores late results. Per-conversation text, attachments and reading position persist in the existing conversation file, with backwards-compatible optional decoding. |
| Models | Registry and runtime snapshots distinguish selected, installed and loaded. Canonical host selection IDs map to registry IDs. Discovery, Core AI packs, download/import, storage, configuration, export and deletion use existing destinations/services. Detail-sheet actions defer until dismissal so the next presentation can open. Per-model commands hide unsupported export/delete actions. |
| Lens | Host camera preview and capture lifecycle, Ask / Translate / Scan / Solve, photo import, vision selection, options and history remain connected. Permission failures explain recovery. Results use the existing analysis/code/review/Q&A implementation. Stop calls the host-owned `AnalysisService.cancelCurrentAnalysis()`. Unsupported camera flipping is omitted. |
| Voice | Catalog selection and preview remain independent. Preview does not overwrite the saved voice. Session microphone, speaker, end and minimize are separate. Minimize preserves the active session. Preparation cancellation cannot later open the microphone. Existing model selection, audio route picker, retry, interrupt, replay and diagnostics remain reachable. |
| Image studio | The completed image and its captured original prompt sit above the next-image dock. Editing the next prompt cannot relabel the result. Existing model download/selection/deletion, settings, create/cancel and share operations remain connected. The previous result stays visible during a new generation. |
| Settings and Device | Native grouped settings, persisted System / Light / Dark, actual runtime/storage measurements and existing preference/utility destinations. Legacy OLED settings resolve to dark appearance. Missing measurements do not become invented numbers. |
| Secondary surfaces | Onboarding, legal acceptance/documents, model pickers/managers, analysis history/results, attachment sheets, voice settings, benchmark, quality evaluation, compare, macros, personas, snippets, knowledge base and bridge pairing use the same native navigation, semantic type and shared neutral palette. Existing confirmation and legal read gates remain. |

The compatibility theme (`KoduTheme`, `KoduComponents`, `StudioTokens`) now supplies the current palette and semantic type to retained rich-content and utility views. The old decorative orb, halo presentation and download confetti are removed from the current shell.

## Validation performed

Environment: Xcode 27.0 beta (27A5218g), iOS 27 SDK, iPhone 17 and iPhone 17 Pro Max simulators on iOS 27. The app uses device-only CoreAI, so production is compiled for a generic iOS device; simulator screenshots come from the package and the isolated review host.

| Check | Result |
| --- | --- |
| Production workspace, `OnDeviceMax`, Debug, generic iOS device, signing disabled | Build passed. This verifies compilation/linking, not a device launch. |
| Supplied `Packages/OnDeviceUI/Scripts/verify-on-mac.sh` | Simulator demo build passed. |
| `QA/NativeUI` UI suite | 10 tests passed: empty Send and attachment removal; multiline Return and Send/Stop; rejected draft retention; original image caption versus next draft and keyboard dismissal; system tabs/drawer/model readiness; independent voice controls and minimize/end; 320-point composer and denied camera state; largest accessibility composer; Settings/onboarding rendering; Lens cancellation dispatch. |
| Additional large-phone UI checks | Width/hit-target measurements at all four probes and Unicode/refocus behavior passed. The corrected accessibility test explicitly verified Reduce Motion/Reduce Transparency on, audited control descriptions, then verified both original off values restored. The final focused run succeeded; evidence is in `accessibility-final.log`. These are 3 additional retained UI cases, for 13 total. |
| `QA/NativeUI` host-contract suite | 7 tests passed using production persistence/request types: draft and reading-position round trips, legacy decoding, cancelled-operation admission, stale cleanup, delayed acknowledgement, conversation/model switching, attachment identity, and recoverable interrupted drafts across relaunch. |
| `OnDeviceUI` contract suite | 5 retained tests cover readiness, immutable intent ownership, image result separation, voice presentation state and appearance persistence. The former constant-only layout test was replaced by actual rendered width/hit-target checks. |
| Existing `VoiceAgentOrb` suite | 25 tests passed in 6 suites. A fresh scratch directory resolved an old SwiftPM Metal-toolchain cache path. No toolchain installation was needed. |
| Repository checks | `scripts/validate_open_source.sh` and `git diff --check` passed. |

Native screenshots were visually inspected for the multiline composer and keyboard, dark appearance, 320-point layout, largest accessibility text, native tabs, drawer, installed-but-unloaded model, denied camera, voice controls, actual host image-result/draft view and actual host onboarding. The Settings screenshot shows the package's grouped presentation; the larger production Settings implementation was source-reviewed and compiled.

See the local [screenshot gallery](../build/native-ui-evidence/index.html) and logs in `build/native-ui-evidence`. These are native simulator captures with fixture data, not generated design mockups. The QA host explicitly avoids real inference, downloads, recording, camera capture and network requests. It includes the actual production image/onboarding/persistence sources and uses isolated service stubs where necessary.

Reproduce the simulator checks using [QA/NativeUI/README.md](../QA/NativeUI/README.md). Earlier failed iterations remain in Xcode's local test history. The complete original UI run passed all 10 tests; the 3 added cases passed in focused runs. A temporary simulator cleanup test also passed and was removed after restoring the preferences. Settings must be reopened before cleanup taps on this SDK; checking its switch values caught and corrected an initially ineffective test interaction.

| Critical scenario | Status | Evidence / limit |
| --- | --- | --- |
| Production compilation and package demo build | PASS | Xcode 27 beta, iOS 27; production signing disabled. |
| Composer geometry, newline, attachments, native navigation, image caption and accessibility presentation | PASS | 13 retained native UI cases across focused runs; isolated fixtures. |
| Draft ownership, persistence, cancellation admission and stale completion | PASS | 7 host-contract and 5 package-contract tests; real engine lifecycle remains a device check. |
| Signed production launch | FAIL | Xcode requires a development team for both app and share extension. |
| Actual inference, model loading, camera, audio, image generation and complete production VoiceOver review | NOT RUN | Signed production launch blocked; simulator cannot run the device-only CoreAI app. |

## Remaining acceptance

- Run the signed production app on a compatible available iPhone: real text and attachment submission, streaming Stop, model load/failure/recovery, draft and reading-position restoration across process launch.
- Exercise physical camera capture/import and result cancellation, actual microphone permission denial/recording, speaker output, voice interruption/minimize/resume/end, and real image generation/share.
- Inspect every production utility and nested preference destination on hardware. Source/build coverage does not establish pixel-level validation of every destination.
- Check VoiceOver navigation and announcements on the production app, including the rich transcript and all utilities. Native Reduce Motion/Reduce Transparency and control descriptions were exercised in the simulator review host; the complete production app still needs its signed device run.

The production target supports portrait only; landscape rotation is outside its current supported configuration. The redesign preserves that configuration. Full marked-text IME composition, native edit-menu/undo behavior and production interactive keyboard dismissal remain part of hardware acceptance; the simulator tests establish newline, Turkish text, multiline editing, explicit dismissal and refocusing.

## Baseline and scope

The repository already contained extensive uncommitted work. The original local package and key bridge/composer sources were copied to ignored `build/ui-redesign-baseline` before replacement. No commit or release package was requested or created. This redesign did not change production app identity, signing, entitlements, model paths or permission descriptions; pre-existing repository changes are retained.

The supplied documentation and demo stay separate from production resources. The supplied example image is a demo/QA fixture only. No downloaded fonts, model weights or new third-party libraries are added.
