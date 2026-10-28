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
| `-screen agent-chat`, `-agent-completed`, `-agent-waiting` | Production tool summary/pills, expandable log and selectable output, conversation details, reasoning timer/disclosure, streaming bar, compaction notice and composer; optional completed or waiting phase |
| `-screen agent-chat -agent-waiting -agent-image` | Sent-image preview while the fixture advances through reply phases; no model inference |
| `-screen agent-chat -agent-completed -agent-details` | Opens the production glass conversation sheet directly for material/spacing review |
| `-screen api-providers`, `-screen api-chat`, `-api-empty` | Production provider settings/model picker with isolated credential storage and a mocked catalog; all model selection stays in the top bar; optional empty configuration |
| `-screen api`, `-api-running`, `-api-starting`, `-api-generating`, `-api-failed MESSAGE` | Production local server workspace with isolated listener state and sample key; no sockets |
| `-api-no-address`, `-api-no-model`, `-api-model-loading`, `-api-model-unloaded`, `-api-model-not-installed`, `-api-model-failed MESSAGE`, `-api-cloud-model` | API workspace LAN, model recovery and cloud-selection boundary cases |
| `-screen github-settings`, `-screen github-chat`, `-github-enabled`, `-github-selected`, `-github-disconnected` | Production GitHub settings, repo/branch picker and review with mocked HTTP and isolated credentials; default-off toggle, optional enabled/selected/disconnected state |
| `-screen coding` | Production Code editor, file tree, context, diff, checkpoints, preview and export with deterministic repository files and isolated credentials |
| `-screen home`, `conversation`, `models`, `voice`, `lens`, `settings`, `device` | Current package screen and native shell |
| `-screen image`, `onboarding` | Actual host view with isolated state |
| `-screen user-guide` | Production User Guide with annotated captures and workflow diagrams |
| `-review-language hi`, `de`, `es`, `ar`, `tr`, `ja` | Persist the UI language for localization review without changing device language |
| `-dark` | Dark appearance |
| `-compact` | 320-point content column |
| `-width 320`, `375`, `393`, `430` | Measured content-width probes; use a simulator at least as wide |
| `-long-model` | Long model label with its full accessible value |
| `-large-type` | Largest accessibility text in the composer fixture |
| `-attachments`, `-no-microphone`, `-reject` | Composer acceptance and capability cases |
| `-model-unloaded`, `-camera-denied`, `-lens-analyzing` | Explicit model/Lens state fixtures |
| `-model-actions -model-preparing`, `-model-actions -preparation-paused` | Model storage preparation progress and resume/storage guidance |
| `-coreai-installed zoo-qwen3-0.6b-official-ios` or `-coreai-installed zoo-laya-multilingual` | Installed Core AI pack deletion, confirmation/cancel and download-again fixture |

For manual Argent review without launch arguments, add a
`RepackPreparationFixture` string to the **built review app's** `Info.plist`,
with value `preparing` or `paused`, then install and launch that QA bundle.
The override only controls fixtures; it does not convert or download a model.
For API server review, use an `APIServerReviewFixture` string in a copied built
QA bundle: `stopped`, `running`, `generating`, or `dark-large-type`. This opens
the production server workspace with fixture services and English labels.
For classifier print review, use `ClassifierPrintReviewFixture` in a copied
built QA bundle: `text`, `dark`, or `image`. These open the production machine,
paper ticket and native classifier controls with sample input and fixture scores.
Tap Activate model, then Classify; tap the ticket to inspect/export its scores.
For Core AI removal review, use a `CoreAIRemovalFixture` string with a catalog
pack ID in the built review bundle. This changes fixture state only; filesystem
removal and selection recovery are tested separately with temporary packs.

For App Store screenshot capture, set `AppStoreScreenshotScene` in a copied
**built review app's** `Info.plist` to `home`, `conversation`, `sidebar`,
`models`, `voice`, or `image`. Install and launch that QA copy through Argent.
The presets use the production interface with illustrative conversations and
model state. They use public catalog identities, omit fabricated storage and
performance measurements, and show Image Studio before generation. The image
preset uses the QA host's in-memory parental-control storage; production
Keychain protection is unchanged. These captures establish interface
appearance, not download, inference, voice, or camera functionality.

The 1.0 (81) English screenshot set is under the ignored
`AppStoreScreenshots/1.0-81/` directory. Its manifest records the source,
dimensions, alpha status, and SHA-256 of each original native PNG. Upload the
six files in `en-US/iphone-6.9/` in numbered order. The local `preview.html`
gallery is for review and is not an App Store upload asset.

These fixture flags do not change system accessibility settings. The Settings fixture forces its launch appearance, so its screenshot establishes rendering only; appearance persistence is checked by the package contract test. Voice controls verify separate intents/state, not audio output.

Xcode 27 beta reports invalid frames for some SwiftUI leaf elements. The UI tests tap the stable containing row/navigation bar for those controls, then assert the resulting state. The shared composer's actual control/writing frames are measured by XCTest. Native PNGs are saved in the runner's `Documents/NativeUIReviewScreenshots`, with paths recorded in `.xcresult` attachments; this keeps captures accessible even when Xcode result finalization is slow or incomplete. The script copies those original files to `build/native-ui-evidence/latest-ui`. Stop other simulator automation servers before running XCTest to avoid competing foreground apps.

The accessibility test temporarily enables the simulator's native Reduce Motion and Reduce Transparency settings, verifies voice controls and their accessibility descriptions, then restores both settings. This is separate from a manual VoiceOver navigation/audio review. The host-contract tests cover delayed acknowledgements, cancellation draining, conversation/model changes and persisted recovery drafts using production types.

See [the integration record](../../Docs/NATIVE_UI_IMPLEMENTATION.md) for production build commands, scope and remaining hardware checks.

The current navigation checks cover home/sidebar search, persistent pin metadata,
opening and creating chats, secondary destinations, Voice shortcut, edge gestures,
draft/attachment retention, and the host selection signal for Lens activation.
The latest user reference explicitly removes the former native TabView.
