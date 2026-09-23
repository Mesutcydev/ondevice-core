# Build 42 candidate — chat regression and UI audit

## September 20 follow-up: successful physical run confirmed

After the user unlocked the paired iPhone, read-only retrieval succeeded. The
installed application is **1.0.0 (42)**. Its diagnostic trace records Ornith 1.5
9B completing the request that started at 05:14:23 UTC on September 20:
prefill finished at 05:14:37, the first token arrived at 05:14:37.674, and generation
completed at 05:14:39.875. A subsequent short generation also completed.
No prompts or response text were retrieved from conversation storage. The local,
untracked trace is `build/uiux-phone-diagnostics.log`.

This confirms that build 42 can answer with the reported model on the user's
physical iPhone. It does not prove the exact cause of the older build 41 stall:
that trace shows one cancelled prefill and a later prefill without a recorded
completion. Camera pixels, real speech and route changes, and physical execution
of the subsequent UI build still require device checks. The original candidate
assessment below is preserved as historical evidence.

## Original build 42 candidate assessment

The user reported build 41 remaining on **Generating** with an empty assistant
turn on Ornith 1.5 9B, and a Voice search bar stacked below Start conversation.
The screenshot's vertical mark is the old empty-stream caret, not evidence that
inference produced its first token.

The paired iPhone 17 Pro Max initially connected. Read-only inspection confirmed
OnDevice Max 1.0.0 (41) and a diagnostic log updated at 23:48 on September 19.
The device disconnected before its log could be copied. CoreDevice then reported
4016 and the device became unavailable. No phone data or installed app was
modified. Hardware inference remains unverified; the simulator harness cannot
run the production Core AI runtime.

## Findings and changes

| Priority | Finding | Change / status |
| --- | --- | --- |
| P0 | The reported first-token stall has not been reproduced or traced on hardware. | **Open.** Read the existing runtime trace when the phone reconnects; do not call this release-ready based on fixture tests. |
| P1 | Returning to retained Chat always called Voice.stop(), even when Voice was idle. That routine cancels the shared assistant runtime. | Added WorkbenchVoiceHandoff. Idle Voice cannot cancel Chat; live Voice still ends when entering Chat or Lens. Home, Models and Voice preserve a minimized session. |
| P1 | All seven normal assistant-generation call sites omitted the runtime error callback. A failed GGUF request could leave an empty reply without an explanation; completion could also enter reasoning recovery after an error. | Added a shared host dispatch wrapper. It retains the first backend failure until completion, then ends that placeholder and displays a separate failure notice with Retry. Successful callbacks, tools and reasoning retain their existing paths. Errors never become model-facing conversation content. |
| P1 | A failed or interrupted first reply could trigger background title generation. | Persist without auto-titling while a response streams, after interruption, or when a generation failure is present. |
| P2 | Voice native search defaulted to the bottom and stacked beneath Start conversation. Models had the same risk with its active-voice footer. | Explicit navigation-bar search placement on both screens. Hide the action footer while search has focus. Voice search collapses its summary/engine rows; model search hides unrelated storage utilities. |
| P2 | The composer's model pill stretched across unused space. | Use the label's natural width with flexible space before dictation and Voice/Send/Stop. Keep native control dimensions and the large-text stacked layout. |
| P2 | Empty streams showed a caret and “writing” before any text arrived. | Show a native progress indicator with “Preparing reply”; start text/caret rendering when text exists. |

## Callback and retry invariants

- Captured operation, conversation and model identity still gate all callbacks.
- A stopped or switched-away request cannot publish a later failure to a new chat.
- Error completion does not launch tool or reasoning follow-ups.
- Retry reuses the existing last user turn, preserves a separately typed next
  draft, and reloads the selected model through the existing loader when needed.
- Navigation still uses the host's existing memory, camera and voice cleanup.
- No model weights, sampler settings, context budgets, residency admission,
  thermal protections, backend implementation or network policy were changed.
- New diagnostics record request lifecycle events and random request IDs only;
  no prompts, responses, attachments or captured media are logged.

## Verification evidence

- Real generic-iOS Debug build passed in `build/blocker-device-build.log`.
- A mounted SwiftUI callback probe passed: asynchronous tokens and completion
  survived the send-state mutation/render. It did **not** reproduce a lost
  response and is not a hardware inference test.
- All 28 distinct UI flows passed across the full audit and final focused runs.
  The initial full run passed 26 of 27: one rejection test received keyboard
  input out of order during a simultaneous build. Its focused rerun asserted
  the typed value before Send and passed draft/attachment preservation.
- The new failure/Retry flow initially exposed an inherited accessibility
  identifier hiding the button's identifier. The identifier now belongs to
  the heading. The final flow passed at 320-point width in dark mode: Retry
  becomes Stop, dismisses the failure, and preserves the next typed draft.
- All 15 host contracts passed (4 XCTest + 11 Swift Testing), including the
  idle-Voice cancellation guard and asynchronous callback probe. All 6 package
  contracts passed. These are presentation and routing checks, not real model
  execution.
- Search tests passed for Voice and Models, including typing, filtering, top
  placement, and hiding the Voice footer while search is focused.
- Repository hygiene and `git diff --check` passed.
- Native screenshots: `build/native-ui-evidence/release-blocker-audit/`.
- Visual inspection confirms the shorter model pill and clear space before
  microphone/Send. The screenshot-diff tool incorrectly reported no change
  for that pair, so its percentage is not used as evidence.
- Logs: `build/blocker-full-ui-audit.log`,
  `build/blocker-targeted-final.log`, `build/blocker-retry-final.log`,
  `build/blocker-package-contracts.log`, and
  `build/blocker-repository-validation.log`.

## UI/UX audit coverage

| Surface | Verified in the native harness | Hardware boundary |
| --- | --- | --- |
| Home and sidebar | Open/new chat, pinning, search, feature destinations, edge gestures, selected state, retained draft and attachments; light, dark, OLED and larger text. | Real persisted histories remain owned by the existing host store. |
| Composer | Text and image previews, removal, model menu, multiline return, leading keyboard dismissal, Voice/Send/Stop dispatch, rejected-send preservation, long model names and narrow widths. | Audio recording and actual generation need the phone. |
| Chat lifecycle | Callback scope survives rendering; idle Voice does not cancel Chat; errors and Retry have distinct accessible controls and preserve the next draft. | The reported first-token stall remains open. |
| Voice | Preview and selection dispatch independently; minimize/return preserves a session; top search filters voices without stacking another footer. | Speech, audio routes and a complete spoken exchange need the phone. |
| Models | Installed/discover filtering, storage navigation, model readiness actions, search placement and return to active Voice. | Actual downloads, loading and inference are not simulated by these flows. |
| Lens | Permission-state presentation, navigation-to-host lifecycle and Stop cancellation dispatch. | The simulator cannot establish a real camera feed or production vision inference. |
| Settings and accessibility | Explicit appearance choices, true OLED, onboarding navigation, larger text and system accessibility preferences. | No new hardware-specific settings behavior was introduced. |

## Build 42 test artifact

- `./scripts/build_sideload_ipa.sh build/releases` passed all eight stages,
  including catalog/direct download checks and the full Release archive.
- IPA: `build/releases/OnDeviceMax-sideload-entitled-1.0.0-42.ipa`.
- Size: 46,096,268 bytes.
- SHA-256: `86692fd812abe68aa60f0fd1fa01d4f3936db3fb3f7f6d6b74362eeedb152232`.
- Verified the sole `Payload/` root, nested signatures, share extension,
  llama/whisper frameworks, Core AI linkage and privacy resources. App-group,
  iCloud, Private Cloud Compute, increased-memory and extended-address-space
  entitlements remain present. Installer-side re-signing is required.
- All 440 production source fingerprints still match the pre-archive snapshot.
- Copied to the existing shared iCloud `OnDevice Builds` folder; the copied
  file's size and SHA-256 match the verified local IPA. Foundation confirmed
  `isUploaded = true`, `isUploading = false`, and no upload error.
- This artifact contains the confirmed fixes and diagnostic improvements;
  it does **not** clear the hardware inference release blocker.

## Required hardware follow-up

1. Copy `Library/Application Support/Diagnostics/diagnostics.log` from the
   `com.mesutcydev.ondevicemax` app container when the paired phone reconnects.
   Inspect lifecycle, assistant load, prefill chunk, first-token and completion
   events; do not request or log the user's conversation contents.
2. Reproduce a short new-chat request, a follow-up, Stop during preparation,
   and return to an in-flight chat through Home/Models/Voice.
3. If the runtime is failing, diagnose the explicit failure. If prefill stalls,
   examine the actual native stage and measured resource state. Do not remove
   safety checks or alter model budgets speculatively.
4. Confirm camera preview and real microphone/speech/inference behavior on the
   phone before clearing the release blocker.
