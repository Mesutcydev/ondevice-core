# UI polish and Aperture voice orb — 2026-09-16

This pass keeps the app's neutral palette, navigation, model selection, and
runtime boundaries. The artwork is original procedural code; it adds no asset,
dependency, model, or network request.

## Motion audit

| Before | After | Why |
| --- | --- | --- |
| A second mode change restarted a 220 ms blend from the previous target, even when that shape had not been reached. | `ApertureOrbMotion.retarget` preserves the current shape and spring velocity. All states share the same ribbon topology. | Rapid thinking → preparing → speaking changes no longer reset the visible geometry. |
| Reduced rendering discarded every other particle. | The lighter path draws complete ribbons with fewer segments. | Preserves a coherent silhouette instead of producing a patchy point cloud. |
| A symmetric, fast audio response closely followed small dips. | Noise floor, 100 ms attack, and 320 ms release. | Keeps speech responsive while softening gaps between syllables and room noise. |
| The native orb used up to 120 Hz and full screen-scale resolution. | At most 60 Hz / 840 pixels; constrained mode uses 30 Hz / 600 pixels. Low Power Mode, thermal pressure, devices with at most 4 GiB memory, and the existing rendering preference constrain the budget. | Bounds visual work alongside local inference. These are policy caps, not measured device frame rates. |
| Reduce Motion still ran a slow animation at 15 Hz. | Native rendering pauses; semantic state changes draw a static pose with no audio deformation. | Respects the user's motion preference and avoids unnecessary redraws. |
| Detaching an active native view could leave its render loop running. | Window attachment, scene activity, view visibility, and scroll visibility gate drawing. | Hidden views do not keep rendering. |
| Orb layout relied on a GeometryReader's unconstrained height inside a ScrollView. | A fixed 280-point layout slot contains the responsive sculpture. | Growing transcripts cannot squeeze the orb's layout space. |
| An interrupt flashed a large white disk over the sculpture. | A quiet outline provides feedback and is suppressed with Reduce Motion. | Avoids a distracting full-surface flash. |
| The standalone package enqueued a deferred task for every display-link tick. | At most one pending publication carries the latest timestamp. | Prevents replay of stale visual frames after a main-thread stall. |
| Package quality recovery depended on another system notification after its hold period. | One cancellable recheck completes the existing recovery hold. | A recovered device can return to its normal quality without an unrelated event. |
| The Voice library animated broad bars even when no preview was playing. | Slender, quiet bars stay static at rest; playback is capped at 24 Hz. | Reduces visual noise and idle work. |

The native renderer submits one depth-tested, multisampled triangle draw, with
24,192 vertices at the normal budget or 11,520 at the lighter budget. At most two
GPU submissions are in flight; a busy queue skips a visual frame rather than
blocking inference or accumulating latency. Dragging tilts the sculpture and
releasing it returns to the neutral view. Existing start/interrupt behavior and
accessibility identifiers remain in place.

**Verdict: Approve the code and simulator behavior.** Transition continuity,
static Reduce Motion, and bounded rendering are covered. Physical older-device
frame pacing under concurrent inference still needs hardware measurement;
simulator rendering does not establish those performance results.

Implementation references: `Packages/VoiceAgentOrb/Sources/VoiceAgentOrb/ApertureOrbMotion.swift:50`
(continuous retargeting), `IOSLocalLLM/Views/Voice/VoiceActivityOrb.swift:151`
(render budget/lifecycle), `IOSLocalLLM/Views/Voice/VoiceIsolatedContainers.swift:45`
(stable layout), `Packages/VoiceAgentOrb/Sources/VoiceAgentOrb/VoiceAgentOrb.swift:337`
(coalesced clock), and `Packages/VoiceAgentOrb/Sources/VoiceAgentOrb/VoiceOrbPerformancePolicy.swift:211`
(recovery).

## Shared UI and onboarding

- Fixed system-font fallback: private UIKit SF font names passed through
  `Font.custom` were rendering as a serif face on the installed OS. Native
  SwiftUI fonts now preserve the intended sizes and scale with Dynamic Type.
- Shared screen headers, search fields, selected filters, and primary buttons
  bring Home, Voice, and Models into the same type and spacing hierarchy.
  Search clear actions keep a 44-point target without changing field height.
- Assistant entry controls and Lens overlays use consistent touch targets and
  readable camera-safe contrast. Lens mode controls reflow with large text.
- Onboarding has three steps: a hands-on introduction, local/connected choices,
  and the existing device-aware model picker. The preview never samples live
  microphone or playback levels. It does not start voice services.
- Back and Explore first remain available. Model download sizes and the
  download action are explicit; the existing residency, admission, download,
  retry, and skip behavior remain intact. Scrollable content and safe-area
  controls replace fixed clearance spacers.
- Privacy copy now distinguishes local models from optional cloud, web, and
  Mac connections. It no longer promises that nothing can ever leave the
  device or names obsolete hard-coded runtime versions.

## Validation

- `swift test --package-path Packages/VoiceAgentOrb --scratch-path /tmp/ondevice-ui-polish/orb-build`:
  30 tests pass, including five new Aperture tests for interrupted transitions,
  30/60 Hz shape equivalence, static Reduce Motion, finite audio/pause recovery,
  and constrained-device budgets.
- Production iOS Debug build: passes with the real workspace and dependencies.
- Simulator visual build: passes using an isolated temporary project that
  removes the simulator-incompatible CoreAILM package product. The app's
  existing `canImport` fallback is used. Production project settings and model
  runtime sources are unchanged by that workaround.
- Simulator checks cover the shared typography, Voice selection/search
  recovery, onboarding navigation and model selection, and accessibility text
  size, plus light and dark orb rendering. All four existing Voice UI tests
  pass. A fifth UI test exercises all six Aperture modes and verifies the
  lighter-rendering and Reduce Motion switches. Its retained screenshot is in
  `build/UIPolish-DD/Logs/Test/Test-OnDeviceCoreAIStudio-2026.09.16_16-11-38-+0300.xcresult`.
- `git diff --check`: passes.
- Repository validator remains blocked by the existing version-metadata
  mismatch: `CITATION.cff does not declare version 1.0.0`.

The DEBUG-only orb showcase uses the existing UI-test entry point:
`-voiceUITestMode -orbShowcase`. It exposes all six non-error poses, an audio
level control, lighter rendering, and Reduce Motion without loading models or
requesting microphone access. The interactive visual review mirrors the native
geometry and state parameters; it is not a hardware performance benchmark.

## Studio identity and copy follow-up

The product identity remains **OnDevice Core**, with **Your local AI studio**
as its positioning. Assistant is for questions, writing, learning, and ideas;
coding remains a supported task and an explicitly selectable persona.

- The empty conversation opens with “What would you like to explore?” and
  learning, writing, and idea prompts. Tapping a prompt fills the composer for
  editing. Both Assistant entry paths now use broader suggestions. An unloaded
  model no longer claims to be getting ready in the welcome subtitle.
- Home, onboarding, the User Guide, model-library copy, and camera/photo/voice
  permission explanations reflect the studio's broader capabilities. Local
  model descriptions distinguish optional cloud and connected features.
- Settings → About presents the app, its version, MIT source-code license,
  model-license distinction, `https://ondevice.fun`, and
  `https://github.com/Mesutcydev/ondevice-core`. Settings search includes the
  website, GitHub, and open-source keywords. The existing related-product card
  remains, with wrapping text in place of clipped badges.
- The new welcome, starter labels and prompts, studio tagline, and source-link
  labels are included in all 14 supported translations. Technical identifiers,
  saved persona IDs, and upstream attribution are unchanged.
- Permission strings were changed in `project.yml` and regenerated with
  XcodeGen. After CocoaPods integration, the generated project was verified
  semantically identical to the existing project; its original UUIDs were
  retained to avoid unrelated churn.

Visual checks use the same isolated Simulator build described above. Both
external links were opened from About and reached the intended website and
public repository. The learning suggestion was verified to insert an editable
prompt without sending it or loading a model. About was inspected in light and
dark appearance and at the accessibility-large text size; links and license
copy wrap without clipping. The final production iOS and isolated Simulator
Debug builds pass, as does `git diff --check`. Review captures are in
`build/ui-polish/about-studio.png` and `build/ui-polish/about-studio-large-text.png`.
The repository validator's
existing citation-version failure remains unchanged.
