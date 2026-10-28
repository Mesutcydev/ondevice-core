# Conversation reference adaptation — October 22, 2026

The owner supplied an OpenCode iOS reference handoff and six example photos,
with an explicit requirement to preserve OnDevice's design and stronger existing
features. The reference is evidence of interface anatomy, not authority to
replace navigation, execution services, or product behavior.

Source: `opencode-ios-handoff.zip`, SHA-256
`a2b534f60abd095d7e3187897fcba631542c6748f49381682a0e1affb8eb53e9`.
The handoff states that it contains a specification and browser demonstrator,
without app source or production/device validation. No reference images, fonts,
HTML, dependency code, or fallback color tokens are bundled by this adaptation.
The Swift implementation is original project code.

## Screenshot audit and visual decisions

The owner's follow-up rejects a generic settings-list treatment. The first QA
sheet had repeated large white cards, blue list actions, a redundant navigation
heading and substantial unused height. That layout is superseded.

| Owner's example | Visual hierarchy to retain | Adaptation |
| --- | --- | --- |
| Photo 1, return summary | A short heading and sentence remain part of the thread, with a quiet dismissal. | Do not add a standalone dashboard or empty recap placeholder. A real unseen-event source is required before adding this feature. |
| Photo 2, session sheet | One title/workspace block, bare icon actions, then closely grouped model information. Destruction is visually separate. | Use a content-sized native sheet, direct title, compact monochrome action row and one subdued model group. Expand to a scrolling large sheet for accessibility text. |
| Photo 3, expanded composer | Text takes the upper area; the lower control row stays compact and the stop control stays explicit. | Preserve the existing composer and leading keyboard key; do not duplicate model selection in its footer. |
| Photo 4, green annotations | The title and subtitle form one unit between two equal-weight navigation controls. Expanded tool activity is a continuous log. | Add conversation identity inside the existing model capsule. Tool logs use wrapping, ordered rows without individual cards or decorative controls. |
| Photo 5, expanded tool activity | Summary, failed count and output share one reading flow. Secondary actions do not dominate the text. | Keep counts inline at normal type sizes, reflow at large text, and retain full output behind a deliberate detail action. |
| Photo 6, completed thread | Right-aligned user bubbles, unboxed assistant prose, links and tool summaries preserve a clear reading rhythm. | Keep the richer production renderer, its code/media/citations and its existing text column. |

These are hierarchy and behavior observations, not exact pixel/color samples:
the source photos have different crops and scales. Spacing, neutral colors,
system typography, hairlines, press feedback and control sizes come from
OnDevice's own `ODLayout`, `ODPalette`, `ODIconButton` and `ODPressButtonStyle`.
The sheet's height is measured from its content so a short task does not open
an empty full-screen page. Native drag, dismissal and expansion remain native.

The owner's subsequent glass-specific correction also supersedes opaque fills
on the conversation controls. The title capsule and composer use native
`glassEffect(.regular)` surfaces; the title capsule supports native interaction
feedback. The session sheet uses one continuous native glass backdrop with a
recessed translucent model group. Opaque chat navigation/footer backgrounds are
removed so the material can sample the content beneath it. Transcript text and
tool output remain ordinary readable content. The system glass renderer owns
light/dark adaptation and reduced-transparency behavior; no copied raster blur,
photographed tint, or fabricated texture is used.

## Adaptation boundary

The retained `OnDeviceWorkbench` sidebar remains the navigation shell. The
production chat remains `CodingAssistantView`, with its richer Markdown/code
renderer, reasoning, citations, attachments, dictation, personas, sampling
controls, provider support, shared runtime policy, and authenticated GitHub/Mac
tools. The composer and leading keyboard-dismiss key retain their placement.

| Reference idea | OnDevice implementation |
| --- | --- |
| Two-line conversation identity | Existing model capsule also shows the current conversation title; tapping it keeps the direct model picker. |
| Session control sheet | Existing More options menu gains Conversation details. The native sheet shows the full title, selected model, execution location and selected repository when available. |
| Session actions | Pin/unpin uses `ConversationStore`; search, sharing, model selection and confirmed deletion reuse their existing routes. Presentations wait for the sheet to dismiss. |
| Expandable tool log | Summary counts real completed attempts, with separate failure counts. Existing compact pills remain available when collapsed; expansion shows wrapping rows and explicit status. |
| Inspectable output | Both pills and expanded rows open the same selectable output sheet with Copy. Output starts with an 8,192-character preview and expands in bounded increments. Only the actual available output is shown; arguments, run timestamps and retry controls are not fabricated. |
| Local presentation recovery | Expanded group IDs join the existing per-conversation draft and reading-position record. Optional decoding preserves older saved conversations. |
| Reading safety | Focusing the composer and tool-state updates follow the tail only when the reader was already following. Explicit Jump to latest and submission retain their existing behavior. |

Tool-result parsing removes only the enclosing protocol fence. Embedded code
fences and protocol-like text inside the actual output survive inspection.
The shared summary reconciles updates by durable attempt ID, preserving order;
cancellations are terminal attempts but do not increase the failure count.

## Capabilities kept at their existing boundary

The handoff's context ring requires an authoritative usage/capacity snapshot.
Existing approximate compaction estimates do not establish that percentage.
The existing compaction notice remains; no ring or invented cost is added.

Cross-device completion notifications, mute/unread state, server event cursors,
remote outboxes, queueing, checkpoint forks and an unseen-event recap require
separate supported service contracts. These controls are not introduced by this
UI adaptation. Local inference/background cancellation and opt-in networking
remain governed by the production services. The app's real dictation is retained
instead of substituting the reference's microphone behavior.

## Validation

Use `QA/NativeUI` for production-component rendering and interaction; CoreAI
prevents the full app from running in the Simulator. Focused coverage includes
embedded output fences, legacy decoding, disclosure/draft round trips,
deduplicated attempt counts, tool-detail copy, sheet pinning, keyboard access,
light/dark appearance, compact width and large text. Simulator fixtures establish
UI behavior only, not inference, camera, microphone or device performance.

Local build logs and original screenshots belong under ignored
`build/OpenCodeAdaptation/`; no signed app, installer or model artifact is part
of this change.

### Verification record

- Production `build-for-testing`, generic iOS, signing disabled: passed after
  the final glass changes. Log: `build/OpenCodeAdaptation/production-compile.log`.
- NativeUI review build with the final glass components: passed. Native glass
  sheet capture: `build/OpenCodeAdaptation/evidence/glass-session-light.png`.
- Repository hygiene and localization: passed; the catalog check covers 1,131
  keys across the six required translated languages.
- The production tool-event and summary definitions were also extracted
  unchanged for a Foundation-only Swift contract check: replayed updates retain
  order and do not inflate completion, failure or running counts. The check
  passes independently of simulator availability.
- Before the glass-only refinement, the focused host suites passed 16 tests;
  the conversation sheet/pin/draft and expanded-log/detail/copy UI flows passed.
  The broader run also completed four UI tests before the runner stalled after
  the Stop-flow assertions during teardown.
- Final interaction-suite completion, including the dark large-text keyboard
  flow, remains unverified: subsequent simulator runs stalled during startup
  and were interrupted. These runs are not recorded as passing. The production
  and review compile gates above do not establish physical-device inference or
  performance.
