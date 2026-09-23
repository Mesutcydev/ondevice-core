You are the senior iOS product designer and SwiftUI/UIKit engineer responsible for improving this existing OnDevice AI app. Implement a complete design and usability correction in the repository, with the Local API Server page as the highest priority. Deliver working changes, inspect the rendered app, and fix the problems you find. A written audit or a small color-and-padding pass does not complete this task.

Use the attached screenshots as evidence of the current implementation. Preserve the app's native Apple direction and give every destination a deliberate composition suited to its task. The quality target is a polished native developer tool: clear hierarchy, useful information, restrained materials, readable states, precise alignment, and excellent interaction feedback.

**1. Inspect the real app before editing.**

Read repository guidance, identify the actual app target and installed SDK, inspect the navigation structure, shared design components, relevant views, and their state owners. Locate the live code paths for the API listener, model selection/loading, connection configuration, lifecycle handling, and error reporting. Use the actual repository names rather than inventing a parallel architecture.

Record a concise issue-to-file map, then continue into implementation. Preserve model downloads, local data, existing features, and server behavior while improving their presentation. Preserve the existing network binding, authentication, and foreground/background behavior. Verify any platform API against the installed SDK and official documentation; make availability decisions from the project rather than assumed version numbers.

This screenshot set contains nine files and eight distinct views:

| Reference | Screen | Visible issue to address |
| --- | --- | --- |
| IMG_6482.png | Chats | Loose list hierarchy; message previews and dates recede heavily; large floating New chat action feels disconnected from the list. |
| IMG_6483.jpeg | Lens | A named model appears above “Vision model required · Choose a model”; the lower controls need a clearer model/mode/prompt/capture hierarchy. |
| IMG_6484.png | Voices | Nicole appears in a selected summary and again in the list; selection and playback need clearer relationships; the bottom action must coexist cleanly with scrolling content. |
| IMG_6485.png | Voice conversation | Excessive separation between identity, listening state, and controls; audio route, muted output, and mic state need clearer independent meanings. |
| IMG_6486.png | Image studio | The large empty canvas dominates setup; suggestions form another large list; the heavy composer and Choose model button compete for emphasis. |
| IMG_6487.png | Models | Sparse hierarchy; “Preparing” and “Selected” are weakly distinguished; management links compete with the actual model collection. |
| IMG_6488.png / IMG_6489.png | Device | Readings, storage links, and advanced tools use nearly equal visual weight; the repeated large groups make the page feel like an undifferentiated settings form. |
| IMG_6490.png | API server | Server is “Stopped” while model says “Ready for API requests”; start control lacks emphasis; permanent blue action rows and repeated groups obscure the connection workflow. |

These images establish visual and wording problems, not proof of every interaction defect. Inspect runtime behavior before claiming a functional bug. In particular, model “Preparing” and “Ready” in separate screenshots could reflect a real transition; investigate their state sources.

**2. Establish shared visual rules with distinct page layouts.**

Use the existing native navigation system, semantic type styles, SF Symbols, real system controls, and one restrained app tint. Titles and ordinary content use semantic label colors. Reserve accent emphasis for meaningful actions and selection. Use status color together with text or symbols; avoid broad green paragraphs as generic reassurance.

Keep native navigation bars, sheets, menus, toggles, pickers, search, and tab bars wherever the current architecture uses them. If a tab bar exists, use the actual system component. Give content its own considered arrangement. A camera, conversation, model library, diagnostics page, and server controller should not all become the same stack of rounded settings cards.

Use real platform material APIs where suitable and available, primarily for navigation and floating controls. Keep technical content on stable, readable surfaces. Audit custom gradients, rim highlights, shadows, and duplicate button backgrounds; simplify them where they reduce clarity. Inspect whether existing circular controls are system-rendered before replacing their appearance.

Apply these as starting design tokens in points, adapting to the app's existing coherent tokens and system-owned geometry:

| Role | Starting rule |
| --- | --- |
| Spacing scale | 4, 8, 12, 16, 20, 24, 32 pt. |
| Custom content inset | 20 pt on ordinary phone layouts; align related sections to one content grid. |
| Custom surface padding | 16–20 pt; 24 pt between major sections; 8–12 pt between related elements. |
| Typography | Native largeTitle/title styles for navigation; headline/title3 for key content; body for controls; subheadline/footnote for metadata. Preserve Dynamic Type. |
| Touch targets | At least 44 × 44 pt; separate hit targets must not overlap. |
| Principal action | Approximately 50–52 pt minimum height at default text size; grow when text requires it. |
| Settings rows | Approximately 52–56 pt minimum for one-line rows; intrinsic height for longer labels. |
| Custom content surfaces | Approximately 20 pt continuous corner radius; reserve capsules for controls where that shape makes sense. |
| Technical values | Monospace for addresses, ports, and code; monospaced digits for changing numeric readings. |

Calculate layout from the available container in points. With available width W and inset M, content width is W − 2M. A two-column group with gap G gives each column (W − 2M − G)/2; use it only while labels and values fit, and stack when they do not. System control geometry and accessibility take precedence over decorative ratios.

Align section edges, row baselines, trailing controls, and separator insets consistently. Differentiate primary text, secondary information, and tertiary support through role, weight, spacing, and semantic color. Avoid solving overflow by shrinking text or adding arbitrary offsets. Use actual rendered contrast to judge readability in both appearances.

**3. Rebuild the API server page around operating and connecting.**

The page should immediately answer: Is the server running? Which model will it serve? What can I do next? Where does my client connect?

Keep the native “API server” navigation title and established route. Replace the current top-to-bottom settings-form composition with this order:

1. A compact server summary with the real listener state, one brief explanation, a selected-model disclosure row, and one prominent lifecycle action.
2. A connection section with a real usable address when available, a Copy action, and client-format guidance.
3. Compact configuration for port and screen-awake behavior.
4. Secondary client instructions and the existing connection/lifecycle notes.

The summary is the visual anchor. Use a small meaningful server symbol or status indicator, strong state text, a quieter model row, and a clearly placed action. Avoid a large decorative illustration, terminal wallpaper, charts, or invented statistics. Lower settings can use native grouped rows, but the operational content must have a visibly different hierarchy from the current screenshot.

Replace the enable toggle as the principal lifecycle control with one Start server / Stop server action bound to the real service. Preserve any separate persistent preference if the existing toggle also controls one, and label that preference accurately. Do not leave two independent controls that appear to start the same server. Reserve a stable area for state/progress so transitions do not make the page jump.

At default text size on the screenshot's large phone, keep state, model, lifecycle action, and the connection section in the initial viewport. On the smallest supported portrait phone, at least state, model, and principal action must be immediately visible. Allow normal scrolling and expansion at accessibility text sizes.

**4. Correct API state semantics and actions.**

Model availability, selected model, loaded runtime, listener lifecycle, and client reachability are separate facts. Derive their presentation from the existing authoritative services. Trace whether chat, API, and vision intentionally use separate model selections before unifying anything.

| Actual condition | Required presentation and behavior |
| --- | --- |
| Stopped with an eligible model | “Stopped”; model “Available” or “Loaded” only when accurate; Start server action. |
| No eligible model | Explain the missing prerequisite and provide a direct Choose model action. |
| Selected model still loading | Show actual loading/preparation state. If the existing Start flow loads it automatically, represent that flow accurately. |
| Starting | “Starting…” with native progress; prevent repeated start requests; do not announce an active connection prematurely. |
| Listener running | “Running” with actual active connection details; Stop server action. |
| Listener running but inference unavailable | Explain model availability separately; a bound socket alone does not mean inference is ready. |
| Stopping | “Stopping…” until the service confirms completion. |
| Failed start or bind | A useful failure near the summary, with a relevant recovery action. Remove stale success presentation. |
| Backgrounding stops the server | Reflect the actual lifecycle when returning; retain accurate foreground-only guidance. |

The screenshot's stopped server must never coexist with an unqualified “Ready for API requests.” When only the model is ready, say “Model loaded” or another accurate model-specific description.

Retain useful native feedback for taps, copying, saving, failures, and loading. Avoid a permanent spinner or animation while idle. Make state updates accessible without announcing every rapidly changing reading.

**5. Make API connection details and configuration usable.**

When running, show a client-usable address derived from the actual listener, active port, binding scope, and current network configuration. Keep it readable/selectable and give Copy a proper hit target with brief confirmation. Use wrapping or a bounded technical-text region for long addresses, IPv6, or long hostnames.

Clearly distinguish a same-device address from an address intended for another device. Do not present localhost or a wildcard bind address as a remote client's destination. An active listener does not prove another device can reach it. If a network address is unavailable, explain that accurately rather than inventing one. A configured address shown while stopped must be clearly labeled inactive; it must not look like a live connection.

The screenshot mentions OpenAI, Anthropic, and Ollama compatibility. Verify the actual implemented routes, request shapes, and limits before presenting them. Use a native menu or disclosure for supported client formats. Build any base URL, request example, and API model identifier from real configuration and route behavior. Do not guess that every format uses the same path or that a display name is the API model ID.

Keep examples behind a “Connect a client” disclosure or sheet. Add a concise copyable example only for behavior the app already supports, and verify it against the actual service where the environment permits. If the app already exposes activity or errors, present a restrained secondary view; add metrics only when they have real data and a clear purpose.

For port editing, prefer one native Port disclosure opening a focused edit sheet with a labeled numeric field, current value, validation, and Save/Done. Respect the service's actual supported range; the screenshot describes 1024–65535. An unchanged or invalid value must not produce an enabled save operation. Include a usable dismissal/Done action for numeric entry.

Remove the permanently active-looking “Apply port” row. If retaining inline editing is a better fit for the existing architecture, expose Apply only for a valid pending change. Distinguish the active port from a newly saved configuration. Follow the service's supported restart behavior and communicate when a restart is needed. Never relabel an old listener with a new port before the change actually takes effect.

Shorten the toggle label to “Keep screen awake” and place “While the server is running” in secondary text. Ensure the app's idle-timer behavior follows the real lifecycle, including stop, failure, and foreground transitions.

Retain the existing foreground-only and unencrypted-HTTP/local-network guidance in compact, readable supporting text near connection settings. Preserve their meaning while removing the oversized competing notice container. Present security and availability facts according to the implementation.

**6. Improve each remaining screen deliberately.**

Chats — Refine a native list with a stronger chat-title/preview/date hierarchy, aligned dates, consistent row insets, and gentle separation. Use a native compose toolbar action as the primary New chat entry point, subject to the existing navigation structure; avoid duplicate oversized compose affordances. Keep empty, populated, search, and no-results states coherent. Give empty space a purpose without adding invented content. Inspect the actual conversation and composer reached from this list: keyboard avoidance, attachments, multiline growth, send/stop state, model selection, scrolling, and bottom safe areas must work correctly.

Lens — Keep the image as the main content and arrange the lower area into a compact model row, native mode selector, contextual prompt, and capture controls. Resolve the named-model/“Vision model required” ambiguity using actual eligibility and loading state. Explain whether the model is selected, missing, incompatible, or loading. Gate only the actions that require that capability; photo selection and camera preview need not be disabled unnecessarily. Center Capture relative to the entire usable width, with a properly aligned Photos action. Use a balanced layout without adding a fake right-side function. Adapt the prompt to Ask, Translate, Scan, and Solve using existing behavior. Preserve readable controls over bright and dark imagery, and handle keyboard and permission states.

Voices — Make the current voice summary compact and explicit. The selected voice may remain in the full catalog, but avoid repeating a second large selection treatment. Keep selection and preview playback as distinct interactions with independent accessible targets. Allow only the playback behavior supported by the existing audio manager, including clear stop/loading feedback. Align language filters with the catalog heading. Place Start conversation using safe-area-aware layout with enough list inset that the final voice remains visible and tappable. Adapt that bottom action when search or the keyboard needs the space.

Voice conversation — Keep native call-like controls and make identity, model, route, conversation state, and bottom actions form a balanced composition. Preserve useful breathing room while reducing disconnected empty bands. Use one clear active listening/speaking indicator driven by real state, with a static reduced-motion alternative. Show audio output enabled/muted separately from the selected route and microphone capture state. Use the native route picker where supported by the app. Align output, mic, and End on one control baseline with consistent geometry, clear labels, and native pressed/disabled states. Keep End visually distinct. Preserve session continuity if the existing presentation supports minimization.

Image studio — Redesign the initial state around writing a prompt and choosing a compatible model. Reduce the empty preview's dominance until there is actual content; replace the large blank placeholder with a compact useful empty state. Keep suggestions short and easy to apply; they should populate the prompt without unexpectedly generating. Build a clear composer hierarchy: editable prompt, quieter model/capability row, and one principal action for the current state. Use Choose model when required, Generate when ready, and real progress/cancellation when supported. Keep prompt input usable before model selection unless the backend has a documented reason otherwise. Expand the actual generated image into the main canvas and make existing result actions easy to find. Preserve drafts, aspect ratio, multiline text, and keyboard behavior.

Models — Keep Installed/Discover as native selection controls and give model rows a deliberate information order: name, capability/quantization, real availability/loading state, and selection for the relevant role. Distinguish “Selected” from “Preparing” and “Loaded.” Improve density and spacing without filling the screen with decorative cards. Keep search and capability filtering close to the collection. Place storage and Core AI packs in a quieter management area. Preserve existing import/download/cancel/retry flows and long model-name readability.

Device — Create a compact current-model summary and a clearly grouped set of real runtime readings. Give values enough emphasis to scan, with stable numeric alignment. Keep storage amounts and storage-management navigation related but visually distinct. Put advanced tools in a secondary native section or disclosure that remains easy to discover. Reduce unnecessary grouping and padding so the page has a useful first viewport. Do not draw a storage composition bar unless its categories and denominator are known; app footprint is not total device RAM usage. Allow scrolling for advanced content and large text. A partially visible scrolling row alone is not proof of a clipping bug; verify end-of-scroll reachability and safe areas.

Audit all additional destinations reachable from the sidebar, these screens, and their sheets. Apply the same quality rules to model pickers, settings, imports/downloads, storage, diagnostics, and any other existing pages. Preserve route-specific layouts. Record every discovered destination as improved, inspected and already coherent, or blocked with a concrete reason.

**7. Implement with clear state ownership and reusable components.**

Reuse or refine the existing typography, spacing, status labels, model rows, technical copy controls, and button styling where that improves consistency. Keep each screen's composition local to its purpose. Use the current app state owners and service APIs; a presentation adapter may translate real state, but production status must remain tied to the service.

Use intrinsic layout, native navigation and controls, and safe-area-aware bottom placement. Support long content and large text through reflow. Avoid hardcoded screen dimensions, fixed text heights, deep nested scrolling, keyboard offsets guessed from screenshots, and whole-screen geometry calculations that fight system layout.

Keep view refreshes lightweight. Formatting or visual updates must not repeatedly load models, create listeners, start audio sessions, enumerate storage, or rebuild camera resources. Preserve request lifecycle behavior during navigation and state transitions. Follow the service's established handling of in-flight and streaming requests when stopping, restarting for a port change, or replacing a model. Verify the new controls do not create duplicate listeners or introduce extra request cancellations. Use preview fixtures only in isolated preview/test configuration.

**8. Render, inspect, and verify before declaring completion.**

Implement and inspect the API page first, then finish every remaining destination. Build the actual app target using the repository's required checks. Capture the rendered screens and compare them with the originals at equivalent sizes. Inspect the images, fix defects you see, and recapture after material changes. A successful build alone is insufficient evidence of design quality.

For every main screen, check a large phone and the smallest supported phone, dark and light appearances, default text size and a large accessibility size. Test keyboards on editable screens and scrolling to the last actionable item. Check landscape and iPad layouts where the app supports them. Check VoiceOver labels/focus order, Reduce Motion, and Reduce Transparency. Use targeted state combinations where they expose distinct layout risks rather than multiplying identical screenshots.

For the API page, verify stopped, missing model, model loading, starting, running, stopping, and failure presentation; unchanged/invalid/changed port editing; restart behavior; long addresses; model replacement/unavailability; and background/foreground transitions. Render unavailable hardware scenarios with explicitly identified preview fixtures, and distinguish that evidence from a live service test.

Run meaningful existing tests and add targeted checks where state or lifecycle logic changes: stale readiness, duplicate starts, port configuration versus active binding, and disabled/invalid operations are useful regression cases. For visual-only changes, prioritize rendered inspection and interaction checks over tests that merely mirror view constants.

The result fails acceptance if any of the following remain:

- “Stopped” coexists with an unqualified “Ready for API requests.”
- The API page still looks like the old equal-weight settings groups with minor color changes.
- Start/Stop is difficult to find, duplicated, or disconnected from real service state.
- An unchanged port retains an active Apply action, or a displayed address does not match the actual listener configuration.
- A model's selection, loading, availability, and serving state are treated as interchangeable.
- Essential text, technical values, or controls clip, overlap, become unreadable, or sit behind a bottom action or keyboard.
- Every page is forced into the same generic card layout.
- Decorative metrics, hardcoded production success states, unsupported compatibility claims, or unavailable actions appear in the interface.
- Native controls have been replaced with imitations that lose platform behavior or accessibility.
- The work ends without inspected renders, or preview/build results are represented as physical-device testing.

Deliver the actual implementation, a concise issue-to-change summary with relevant files, before/after images for API server and the other main screens, a destination coverage list, and a truthful account of builds, checks, and any environment limitations. State concrete unresolved items if any remain. Continue through implementation and verification; do not finish after proposing the redesign.

Platform reference: Apple's explanation of Liquid Glass describes controls and navigation as a functional layer above content. Apply that separation while giving the content a layout appropriate to each task: [Apple — software design](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/). Confirm concrete API choices in the installed SDK and current official documentation.
