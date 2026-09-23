# Device screenshot audit — build 39

This pass follows the current neutral native design supplied by the user. It
supersedes the older Instrument styling notes, not the native TabView and
keyboard ownership rules. The nine photos include duplicate Voice and Models
states; each photographed surface was reviewed.

| Photos | Finding | Change |
| --- | --- | --- |
| 1 — Chat | Imported filename dominates the composer, placeholder and Image studio action are faint, dates consume the recent rows, title/caption feel disconnected. | Presentation-only readable model names (full quantization remains in Models and accessibility); stronger semantic placeholder/action colors; Today/Yesterday/abbreviated dates; 8-point title/caption grouping and consistent 24-point section spacing. The actual host welcome view is included in the simulator review target. |
| 2 — Lens | Preview stays black; the instruction field's artwork is much shorter than its touch region. | Direct tab/mode publisher subscription fixes missing host lifecycle events. Instructions now have a visible, padded 44-point minimum input surface that grows with text. Existing capture, Photos, permission recovery and Stop actions remain wired. |
| 3–4 — Voices | Filters sit in a separate section with excessive space; the count describes the entire library even when filtered; green camera indicator can linger from Lens. | Selected voice, engine and filters share a section; section spacing is explicit; count follows visible voices; camera exit uses the repaired selection wiring. |
| 5 — Voice session | Raw model filename leaks into the session identity. | Shared readable model names, retaining model size and quantization. Independent microphone, speaker, route and End controls are retained. |
| 6–7 — Models | A transparent segmented row and white capability row share one clipped group; model name/source repeat the same imported path; an active microphone lacks an immediate visible return control. | Separate native filter sections; readable name plus import provenance; active voice Return/End controls above the system tab bar. Original source identifier remains in model details. |
| 8 — Find Models | Counts appear while Suggestions are displayed, runtime control is undersized, inconsistent insets, verbose storage implementation details. | Counts appear with queried results; native glass runtime menu with 44-point minimum region; 20-point page/12-point inner spacing; concise compatibility guidance and a wired retry action. Search, filtering and downloads retain their existing services. |
| 9 — App menu | Abbreviated elapsed-hour headings fragment conversation history. | Calendar-aware Today/Yesterday/date grouping, refreshed across day changes, with sentence-case semantic headers. All conversation and destination actions are preserved. |

## Boundaries

Model names are transformed only for presentation. IDs, file paths, stored
conversations, loading, inference, capacity policy and download selection are
unchanged. Quantization is kept in the full display name; the composer uses a
short form and exposes the full name to VoiceOver. System tab colors, navigation
bars and Liquid Glass controls retain their native behavior.

The orange microphone indicator in Models can be valid: the app supports
minimizing an ongoing voice conversation. This pass makes that state visible
and provides Return and End rather than silently stopping a supported session.

## Validation

- Host contracts: 2 hosted XCTest lifecycle regressions and 9 Swift Testing
  contracts pass, including filename/identity and calendar-day boundaries
  (`build/polish-native-validation.log`).
- UI: 16 of 17 cases passed on the initial sweep. The failed assertion exposed
  the Lens field's small accessibility frame. After adding a padded focusable
  container, all four affected cases pass (`build/polish-ui-final.log`),
  including a tap on its top padding that actually opens the keyboard. All 17
  distinct UI cases now have passing results.
- Package: all 5 presentation/action contracts pass
  (`build/polish-package-contracts.log`).
- Native screenshots: 27 PNGs in `build/native-ui-evidence/build-39/`; inspected
  welcome, Lens, Voices, voice session and Models in light and large-text dark
  states. Initial inspection caught the voice panel's narrow background and
  the large-text Capture label wrapping; the final captures correct both.
- A saved-screen Argent comparison of the denied-camera state reports 1.50%
  changed pixels. This is supporting evidence, not camera hardware validation.
- Find Models was audited from the supplied device photo and source; its full
  search service cannot run in this isolated host. Release compilation is its
  build check; actual catalog browsing remains an on-device acceptance step.
- Repository hygiene, whitespace, original entitlement and Podfile.lock
  checksum checks pass.

## Release artifact

`OnDeviceMax-sideload-entitled-1.0.0-39.ipa` — 45,938,022 bytes.

SHA-256: `743b9ebb1e135c9153eb8ecab9e8ba883ff9ac57e61c9d7f2902af55b050f15a`.

The repository release script completed all eight stages. An independent
extraction verified ZIP integrity, a Payload-only root, arm64, bundle/build
identity, camera/microphone/photo permission descriptions, privacy manifest,
CoreAI linkage, llama/whisper frameworks and the share extension. Every nested
signature validates. Main-app PCC/app-group/iCloud/memory entitlements and
extension app-group entitlements exactly match the original input plists.
This is a profile-less ad-hoc package requiring installer-side re-signing.

The IPA was copied into the existing shared `OnDevice Builds` iCloud folder;
the copied bytes have the same SHA-256. Finder confirms both builds in the
folder, each marked “Added by Me,” and the folder banner says it is shared
on iCloud. Build 38 remains available.

The
camera regression's failing-before/passing-after evidence is in
[LENS_CAMERA_FIX_2026-09-19.md](LENS_CAMERA_FIX_2026-09-19.md).

The review host uses the production package views and the actual host welcome
view, with isolated service fixtures. It does not provide real camera frames,
run model inference or exercise a microphone. Full production builds use the
device-only CoreAI framework. Physical camera capture and on-device inference
still require testing on the user's iPhone after installation.
