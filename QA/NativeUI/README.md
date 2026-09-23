# Native UI review host

This isolated iOS 27 simulator app verifies the current `OnDeviceUI` package without the production app's device-only CoreAI dependency. It is not a replacement production app.

The host compiles the actual production `ImageGenerationView`, `OnboardingOnePager`, `ConversationStore`, message models and attachment metadata. `HostStubs.swift` supplies isolated image/runtime, diagnostics and indexing fixtures. No test performs model inference, downloads, network calls, microphone recording or camera capture. The sample image belongs only to the review app and supplied demo.

With Xcode 27, XcodeGen and an installed iOS 27 simulator:

```bash
xcrun simctl list devices available
bash scripts/validate_native_ui.sh YOUR_SIMULATOR_UDID
```

The script generates the project beside `project.yml`, runs the UI and host-contract tests, copies original native screenshots from the isolated runner, then runs the package contracts. Use an iPhone 17 Pro Max for the complete 430-point probe; narrower devices cannot represent that viewport without clipping. Generated Xcode projects and DerivedData are ignored. Do not move the generated project into another directory: source and package paths are relative to this folder.

Launch arguments for manual inspection:

| Argument | Effect |
| --- | --- |
| `-screen composer` | Shared composer with explicit fixture status; default screen |
| `-screen home`, `conversation`, `models`, `voice`, `lens`, `settings`, `device` | Current package screen and native shell |
| `-screen image`, `onboarding` | Actual host view with isolated state |
| `-dark` | Dark appearance |
| `-compact` | 320-point content column |
| `-width 320`, `375`, `393`, `430` | Measured content-width probes; use a simulator at least as wide |
| `-long-model` | Long model label with its full accessible value |
| `-large-type` | Largest accessibility text in the composer fixture |
| `-attachments`, `-no-microphone`, `-reject` | Composer acceptance and capability cases |
| `-model-unloaded`, `-camera-denied`, `-lens-analyzing` | Explicit model/Lens state fixtures |

These fixture flags do not change system accessibility settings. The Settings fixture forces its launch appearance, so its screenshot establishes rendering only; appearance persistence is checked by the package contract test. Voice controls verify separate intents/state, not audio output.

Xcode 27 beta reports invalid frames for some SwiftUI leaf elements. The UI tests tap the stable containing row/navigation bar for those controls, then assert the resulting state. The shared composer's actual control/writing frames are measured by XCTest. Native PNGs are saved in the runner's `Documents/NativeUIReviewScreenshots`, with paths recorded in `.xcresult` attachments; this keeps captures accessible even when Xcode result finalization is slow or incomplete. The script copies those original files to `build/native-ui-evidence/latest-ui`. Stop other simulator automation servers before running XCTest to avoid competing foreground apps.

The accessibility test temporarily enables the simulator's native Reduce Motion and Reduce Transparency settings, verifies voice controls and their accessibility descriptions, then restores both settings. This is separate from a manual VoiceOver navigation/audio review. The host-contract tests cover delayed acknowledgements, cancellation draining, conversation/model changes and persisted recovery drafts using production types.

See [the integration record](../../Docs/NATIVE_UI_IMPLEMENTATION.md) for production build commands, scope and remaining hardware checks.

The current navigation checks cover home/sidebar search, persistent pin metadata,
opening and creating chats, secondary destinations, Voice shortcut, edge gestures,
draft/attachment retention, and the host selection signal for Lens activation.
The latest user reference explicitly removes the former native TabView.
