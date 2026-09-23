# September 20 native UI implementation

The supplied UI/UX brief is implemented in the active OnDevice routes. The
September 20 screenshots are the starting-state references, not a requirement
to retain their duplicated navigation and metadata. This pass keeps the single
workspace/sidebar shell and all existing runtime services.

The later API-server navigation change is documented in
[API_SERVER_WORKSPACE_2026-09-20.md](API_SERVER_WORKSPACE_2026-09-20.md).
It supersedes the earlier Mac bridge sheet route.

## Source map and changes

| Surface | Active source | Connected changes |
| --- | --- | --- |
| Chat/composer | `IOSLocalLLM/Views/CodingAssistantView.swift`, `Packages/OnDeviceUI/Sources/OnDeviceUI/Components/ODComposer.swift` | One continuous 24-point surface, 16-point page margins, measured multiline input, model pill, attachments, and Voice/Send/Stop. Usable editing survives setup/loading/failure; missing-model state exposes Load/Choose instead of starting voice as a bypass. |
| Dictation | `IOSLocalLLM/Views/Studio/StudioAddSheet.swift`, `IOSLocalLLM/Views/MicDictationButton.swift` | Explicit **Dictate text** tools destination edits the same bound draft through the existing dictation service. No neighboring mic/waveform ambiguity. |
| Replies | `IOSLocalLLM/Views/ChatResponseActions.swift` | Copy and More; Share, Read aloud, Regenerate and provenance remain available. Raw model/timing details are disclosed in a sheet. Historical provenance never falls back to the currently selected model. |
| Chats | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODConversationsHome.swift` | Native search, existing title/excerpt/activity, pinning, and one New chat action. Removed duplicate Workspaces inventory. |
| Drawer/shell | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODConversationDrawer.swift`, `ODWorkbench.swift`, `IOSLocalLLM/ContentView.swift` | Create/Manage groups, selected destination, current conversation and every existing feature. No duplicate history. Image studio and Device are retained workspaces. Legacy route requests redirect; old generator sheets were removed. |
| Voices | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODVoiceLibraryView.swift` | Compact selection, independent Preview, real language/source filters, engine in options, top native search, setup explanation and inset Start/Return. Preview targets include their full 44-point area. |
| Active voice | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODVoiceSessionView.swift`, `IOSLocalLLM/Views/VoiceConversationView.swift` | Concise identity, explicit output route, Audio on/muted versus Mic on/off, red End, static phase symbol rather than fabricated audio levels. Minimize preserves the session. Permission denial offers system Settings; existing retry/interrupt/audio-route tools remain. |
| Image studio | `IOSLocalLLM/Views/ImageGenerationView.swift`, shared `ODImagePromptSuggestions` | One workspace title, three examples that only fill the prompt, real result canvas, setup/Create/Cancel/Retry, retained prompt and supported options. Negative prompts are hidden when the selected engine's real CFG configuration ignores them. |
| Models | `Packages/OnDeviceUI/Sources/OnDeviceUI/Views/ODModelsView.swift`, `ODModelDetailView.swift`, `IOSLocalLLM/Services/ODBridge.swift` | Native Installed/Discover control, system typography, separate details/download actions, live download snapshots, distinct installed/loaded/selected states. Storage and estimated runtime memory are labeled separately; unknown memory is not a compatibility claim. |
| Device | `IOSLocalLLM/Views/HomeView.swift` (`NativeDeviceView`) | Friendly model name, identifier disclosure, exact state/execution, measured app footprint, precise storage names, scrollable Runtime/Storage/Advanced tools. Every diagnostics/import/download/benchmark/quality route remains. |

Semantic typography and colors, the 4/8/12/16/24/32-point spacing scale, blue
primary actions, native sheets/menus/search and app-owned 44-point targets are
shared across these surfaces. No inference loader, model key, downloaded file,
context budget, cancellation ownership, thermal policy, or network policy was
replaced. Image option support is read from the existing generation configuration.

## Validation and evidence

The real app depends on device-only Core AI. `QA/NativeUI` compiles the production
package, composer, response actions, actual Image studio and Device views with
explicit review-only service snapshots. It does not run model inference or
record audio. Host contract tests exercise production callback ownership,
conversation persistence and navigation lifecycle helpers.

- Before screenshots: `build/native-ui-evidence/uiux-brief/before/` (preserved
  native captures from the preceding candidate).
- After screenshots: `build/native-ui-evidence/uiux-brief/after/`.
- Dedicated iPhone 17 (402 points) and iPhone 17 Pro Max (440 points) simulators
  avoid interference from another app launching in the shared simulator.
- The matrix captures all eight requested surfaces in light/dark and large
  Dynamic Type; the interaction suite additionally covers 320/375/393/430-point
  composer widths, long names, real system Reduce Motion/Reduce Transparency,
  attachments, keyboard input, retry/cancellation, retained drafts, history,
  model setup, voice selection/preview, minimize/return and route dispatch.
- Browse the captures in `build/native-ui-evidence/uiux-brief/index.html`.

The first shared-simulator run was interrupted by another application's launches
and is not used as a passing gate. A subsequent Unicode keyboard test received
out-of-order key events while the device app compiled; its successful focused
rerun ran without concurrent compilation. Test fixes follow the platform's native search
Close action for an empty query and the existing `sidebar.mac` identifier.

## Physical device boundary

Read-only inspection confirms OnDevice 1.0.0 (42) is installed on the paired
iPhone 17 Pro Max. Its retrieved diagnostic trace records the reported Ornith
model producing a first token and a completed reply on September 20 (08:14 local
time), followed by another completed generation. See
[the regression audit](RELEASE_BLOCKER_AUDIT_2026-09-20.md).

That is successful hardware inference evidence for build 42, not execution of
this subsequent UI build. The older stall's exact trigger, real camera pixels,
microphone capture, Bluetooth/AirPlay route changes and a complete spoken
exchange are not established by the simulator fixtures. No phone app was
installed, replaced or deleted during this pass.

## Final results

- All **36 distinct UI scenarios** have passing runs across the isolated suite
  and focused reruns. `build/uiux-scenario-results.json` maps each scenario to
  its passing log; this is not a claim that the initial full run passed.
- The eight-screen matrix passed on both **402-point and 440-point iPhones**
  in light, dark, light with Accessibility 3 and dark with Accessibility 3.
  Logs: `build/uiux-matrix-compact-recovered.log` and
  `build/uiux-matrix-large-final.log`.
- Both devices passed independent playback/microphone mute, End, and full
  session-state scrolling above bottom controls at large text sizes.
- **15 host contracts** passed (4 XCTest + 11 Swift Testing) in
  `build/uiux-isolated-flows.log`; **6 package contracts** passed in
  `build/uiux-package-contracts.log`.
- Composer widths 320/375/393/430, long names, input/attachments, failed model
  setup, download/detail actions, retained image prompts, engine-specific
  options, and system accessibility preferences have passing checks.
- Repository hygiene and `git diff --check` passed. No entitlements changed.

Visual review corrected the primary action's native control size (the regular
style's intrinsic target was only 34 points), native disabled-label treatment,
and the End control's pastel dark-mode fill. End now uses native red. The
final voice reruns passed on both sizes in
`build/uiux-voice-native-red-compact.log` and
`build/uiux-voice-native-red-large.log`. The evidence folder contains 96 matrix
PNGs, including scrolled bottom states, with hashes in `capture-manifest.json`.

An initial capture run exhausted disk space; removing regenerable build caches
allowed the complete matrix to pass. The first large-screen assertion exposed
a test assumption: UIKit reported a preview as hittable below the accessory.
The test now scrolls until the entire target is above Start, then asserts both
geometry and hittability. The passing captures show the actual final voice row.
The first Release compile also caught an optional catalog RAM estimate being
treated as nonoptional. The adapter now preserves absent/nonpositive values as
unknown, without changing runtime admission or loading.

## Build 43 test artifact

`./scripts/build_sideload_ipa.sh build/releases` passed all eight stages in
`build/uiux-release-43-verified.log`, including the catalog/direct-link checks,
full Xcode 27 Release archive, runtime symbol check, resource checks, nested
signatures, share extension and final Payload structure.

- IPA: `build/releases/OnDeviceMax-sideload-entitled-1.0.0-43.ipa`.
- Size: **46,119,398 bytes**.
- SHA-256: `708205d0d7aeb277a6db0e845c67ec8da84bfc578c4c9646fb49ff2bfdadd6c9`.
- An additional comparison verified the complete signed app and extension
  entitlement dictionaries exactly equal their source plists. This includes
  app groups, iCloud, Private Cloud Compute, increased-memory limit and extended
  virtual addressing. **Installer-side re-signing is required.**
- All 337 recorded Swift/configuration/entitlement fingerprints match the frozen
  source snapshot. Verification: `build/releases/OnDeviceMax-43-verification.json`.
- Copied into the existing shared iCloud `OnDevice Builds` folder; the copy's
  bytes and SHA-256 match. Foundation confirms `isUploaded = true`,
  `isUploading = false`, and no upload error.

Build 43 is a test artifact. A physical run of this build, camera pixels,
microphone capture, audio-route changes and a full spoken exchange are still
unverified. The successful phone model trace belongs to build 42.
