# Host integration

This package supplies presentation and an intent bridge. The existing OnDevice app supplies its engines, file ownership and persistent state. It requires the iOS 26 SDK or newer and an iOS 26+ target.

## Add the package

Add the folder containing `Package.swift` as a local package in Xcode and link `OnDeviceUI` to the app target. The package processes its own color resources through `Bundle.module`; do not separately duplicate the catalog into the target.

Create and retain `ODStore` on the main actor. Present:

```swift
OnDeviceWorkbench(store: store)
```

For the existing capture session:

```swift
OnDeviceWorkbench(
    store: store,
    cameraPreview: AnyView(ODCameraPreview(session: existingCaptureSession))
)
```

These expressions belong in the host’s SwiftUI view. `store` and `existingCaptureSession` are host-owned values. `ODCameraPreview` attaches a preview layer; it does not authorize, configure, start or stop capture.

Assign `store.onAction` to the host adapter. Default capability flags are false. Enable each after its real operation is wired, and update published properties on the main actor. Use asynchronous tasks for service work; acknowledge accepted operations promptly so another tap cannot start a duplicate request.

## State and action map

| Area | Host-supplied state | Main intents |
| --- | --- | --- |
| Chat | `messages`, `composerText`, `isResponding`, current/recent conversation IDs | `.sendMessage`, `.stopGeneration`, `.newConversation`, `.openConversation` |
| Attachments | `draftAttachments` and capability flags | `.addAttachment`, `.removeAttachment`, `.sendMessageWithAttachments` |
| Models | `models`, `selectedModelID`, `loadedModelID`, `modelPhase` | `.loadModel`, `.modelAction`, discovery/picker intents |
| Device | Actual `ODDeviceMetrics` | `.manageStorage` and the app’s existing diagnostics routes |
| Image studio | `imagePrompt`, `selectedImageModelID`, `imagePhase`, `imageResultURL`, `imageResultPrompt` | `.generateImage`, `.cancelImageGeneration`, `.openImageModelPicker` |
| Voice catalog | `voices`, selected voice/engine, `voicePreviewID` | Select, preview, stop preview, select engine |
| Voice session | Active/presented state, phase, transcript, microphone/speaker and route | Begin, end, microphone/speaker changes, route selection |
| Lens | Model name, mode, question, status and supplied camera preview | Capture, choose photo, switch camera, options/model selection |

The current root follows the later user-supplied sidebar reference: a conversation home with a leading sidebar, native `NavigationStack` workspaces and sheets. There is no bottom tab bar. `ODTab` remains a compatibility destination enum and its publisher still drives the host lifecycle. Visited workspaces remain mounted to preserve drafts and attachments. Additional routes should respect the currently presented sheet/cover instead of attempting simultaneous unrelated presentations.

## Chat, drafts and attachments

The supplied `ODMessage` presentation is plain text with role and ID. It supports selectable text, Copy and basic active-transcript following. Preserve or reconnect the host’s richer Markdown/code/media renderer, durable history and per-conversation reading-position restoration. The handoff does not replace those services.

The composer is one rounded content surface with attachment metadata, a writing area and a footer. The model selector occupies the centered navigation item; its menu still exposes model details and supported loading actions. The footer has the plain attachment action, a separate capability-gated microphone and the always-visible Send/Stop action. Empty or unavailable drafts disable Send instead of swapping it for Voice. Relevant preparation, error and unavailable-send explanations appear only when needed.

`ODAttachment` is displayed inside the composer above the writing area. It contains `id`, `name` and `kind` (`.file` or `.image`). It represents an attachment already owned by the host. It contains no bytes, file URL, upload state or extraction result. `.addAttachment` opens the existing picker; after acceptance, publish its metadata in `store.draftAttachments`.

`.removeAttachment(id)` asks the host to remove that draft reference. Publish the updated list after accepting the change. Do not delete the underlying user file merely because its draft attachment is removed.

Sending snapshots the draft text and IDs. A text-only draft emits `.sendMessage(String)`; any attached draft emits `.sendMessageWithAttachments(text:attachmentIDs:)`. Resolve IDs through the host’s attachment store and use its supported processing path. Attachment-only sending is possible when the host permits it.

Keep the draft intact until the host accepts the submission. On rejection, preserve it and expose the real problem. When acceptance arrives, clear only the submitted draft; do not erase newer text or attachments belonging to another conversation. Set `isResponding` and the relevant accepted state promptly. Reconcile completion/failure from the real runtime.

## Models and device

Readiness requires a selected installed assistant model, matching `loadedModelID`, and a ready runtime phase. Catalog presence, installation and selection are separate facts. Keep model loading and download behavior in the existing registry/runtime; use actual step labels and recoverable errors.

Publish measured device values or leave them unavailable. Never turn the example sizes, thermal label or storage values into production defaults. Keep storage paths, registry IDs and existing entitlements intact.

## Voice and Lens

Voice selection and audition are separate operations. Publish `voicePreviewID` only for an accepted preview and clear it when playback finishes. Avoid starting previews over an active voice conversation. `Cloned` is a catalog filter using `ODVoice.isCloned`, not a new cloning implementation.

The host accepts a voice start, requests permissions through its existing flow, then publishes session and presentation state. Input/output toggles remain independent. Ending waits for host state; minimizing is available only when the host supports continuation. The small waveform is an informational graphic, not amplitude measurement.

The host owns camera permission, inputs, session queue, orientation, capture and inference. Supply its preview or the provided adapter. Keep Lens actions disabled when their capability is unavailable and expose actual permission/recovery text.

## Image results and appearance

Accept `.generateImage(prompt:modelID:)` as an immutable job snapshot. Publish `imagePhase` from the real generator and enable cancellation only if supported. On completion publish `imageResultURL` and the original `imageResultPrompt` together. Use a distinct file URL per result so the preview refreshes correctly. The editable `imagePrompt` is the next draft and may differ from the displayed result caption.

A local result is decoded for display; a host-controlled remote result may be loaded by the view. The host retains ownership of durable storage and access. The toolbar shares the actual result URL. There is no additional sampler, size or style-settings implementation.

Appearance defaults to a namespaced local preference. If the host already owns persistence, create `ODStore(appearanceDefaults: nil)`, seed `appearance` from the existing setting, and observe/write changes through that same preference system. Do not create competing saved defaults.

The example app has its own preview bundle identity and fixture data. Integrate the library into the production target while preserving that target’s identity, signing, permissions and services.

## Composer voice shortcut

The supplied composer microphone is an **Open Voice** shortcut: it selects the Voice workspace when `canStartVoice` is true and is disabled while a chat response is active. It does not transcribe into the draft. Keep the accessibility label aligned with that behavior. If the production app already supports composer dictation, integrate its real dictation action and lifecycle deliberately instead of treating this shortcut as an audio recorder.
