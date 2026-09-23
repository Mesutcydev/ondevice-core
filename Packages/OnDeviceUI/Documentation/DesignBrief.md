# OnDevice — native iOS design brief

Design proposal · 19 September 2026 · iOS 26 and later

OnDevice is a focused workspace for local chat, images, Lens and voice. Warm neutral surfaces, readable typography and native iOS controls establish the visual system. The app keeps its existing capabilities, models and data.

## Research and adaptation

The primary composer reference is the retained official **Codex desktop demo**, associated with the [official desktop app documentation](https://learn.chatgpt.com/docs/app). We inspected its poster and a frame at 12 seconds: one rounded rectangle contains a writing area above a footer of controls. The material does not expose a build date; it is not proof of an exact current build. Our phone adaptation preserves that composition and includes only OnDevice’s real actions.

| Reference | Observed quality | OnDevice adaptation |
| --- | --- | --- |
| [Hermes design contract](https://github.com/NousResearch/hermes-agent/blob/main/apps/desktop/DESIGN.md) | Chat as home; flat grouping; shared controls; preserved context | Four primary tabs, contextual destinations and clear state |
| [Apple Messages guide](https://support.apple.com/guide/iphone/send-and-reply-to-messages-iph82fb73ba3/ios) | Distinct attachment and writing affordances | Clear, reachable attachment action inside the composer footer |
| [ChatGPT App Store images](https://apps.apple.com/us/app/chatgpt/id6448311069) | Quiet user bubbles and readable assistant content | Neutral right-aligned prompts and plain assistant text |
| [Claude App Store images](https://apps.apple.com/us/app/claude-by-anthropic/id6473753684) | Visible attachment content and restrained transcript | Named draft attachments and clear content hierarchy |

App Store images are promotional references, not live inspections. This is an independent OnDevice design; other products’ branding, agents, connectors, terminals and cloud features do not become app capabilities.

## Native shell

Use real SwiftUI `TabView` for **Chat, Lens, Voice, Models**, with Chat as home. Build with the iOS 26 SDK or later and target iOS 26+. The operating system owns the tab bar’s dimensions, material, selection and tint. Keep the native bar visible, without a root tint override or custom replacement.

Use native navigation, toolbar items, menus, sheets and pickers. Appropriate buttons use Apple’s [`.glass`](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass) and [`.glassProminent`](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glassprominent) styles. Do not recreate native glass using layered blur, gradients, shine or strokes. The composer is an ordinary content surface; its primary action is a native button.

The conversations drawer provides New chat, search, history, Image studio, Device and Settings. It preserves context underneath, has explicit dismissal, and uses a usable scrim. Each tab retains its presentation state; the host preserves conversation drafts and reading positions. Background completions do not navigate or steal focus.

## Content and proportions

Use a warm, nearly white canvas in light mode and neutral charcoal in dark mode. Primary text is ink black or soft white; secondary text is readable gray. Headings and restrained OnDevice wordmarks are monochrome. Use semantic color for meaningful actions and states, not repeated category labels.

Use SF Pro semantic fonts and Dynamic Type. Chat and draft text use `.body` (17 pt at the default setting); secondary information uses `.footnote`. The wordmark may use system serif typography. Separate roles with spacing, alignment and weight; avoid excessive metadata, decorative AI symbols and boxed sections around every row.

The app-owned scale is **u = 4 pt**: page insets 20, message gaps 24, related-element gaps 8, bubble padding 16 horizontally and 12 vertically. Interactive targets are at least 44×44 pt. User bubbles may use up to 82% of the content column, rounded down to physical pixels. Native controls retain their actual intrinsic sizes.

`ODLayout` and `Documentation/LayoutMetrics.md` define the exact equations. With safe-area width W, composer width is `max(0, W − 40)`. Its content radius is 24 pt. Horizontal outer padding 12 plus text inset 4 gives a 16 pt text inset. Top 12, text minimum 44, gap 4, footer minimum 44 and bottom 8 produce a **112 pt minimum before attachments**. Text, accessibility layout, attachments and measured native controls can increase height. The equations specify intended geometry; runtime validation must confirm native control measurements.

## Composer contract

Use one rounded rectangle. Draft attachments sit **inside**, above the writing area. The field occupies the upper area and expands from one through six visible lines. Return inserts a newline; sending is an explicit action.

The footer places the plain attachment action and native model menu on the left. A separately supported microphone and the primary Send action sit on the right. Send stays visible but disabled for an empty or unavailable draft; while responding, it becomes Stop with the host’s cancellation capability. The microphone never replaces Send and must have an unambiguous action label.

The plus and microphone use neutral minimum-44-point targets. Send/Stop uses the real native glass-prominent circular button. At accessibility text sizes, the model menu moves to its own row above the footer icons. Keep a simple conversation title in the navigation header.

`ODAttachment(id:name:kind:)` is metadata for a host-owned attachment, not a file upload or processing result. Add, remove and send use the existing attachment service. Sending snapshots text and stable IDs through `.sendMessageWithAttachments(text:attachmentIDs:)`; clearing waits for host acceptance and must not erase a newer draft.

## Twelve-screen composition

**01 · New chat.** Show restrained OnDevice branding, writing space and meaningful recent conversations when available. Keep Image studio reachable as a quiet destination. Omit generic starter grids, marketing slogans and invented personalized suggestions.

**02 · Conversation.** Align soft neutral user bubbles right. Assistant content flows on the canvas with readable paragraphs, lists and existing rich content. Preserve the host renderer. Follow streaming output only while the user is at the latest content; otherwise provide return-to-latest.

**03 · Conversations.** Make search, New chat and chronological history easy to scan. Only the active conversation is selected. Use native contextual actions for established rename, delete and pinning. Titles may wrap; utilities remain clearly grouped.

**04 · Models.** Use native Installed / Discover selection, search and flat rows. Display real names, relevant quantization and availability. Ornith1.5 9B Q5_K_M and SmolVLM are sample app content, not universal compatibility promises. Values and actions come from the registry.

**05 · Model detail.** Show the full name, aligned metadata and one action/status region. Distinguish installed, selected, unloaded, preparing, ready and failed. Use real operation labels and measurable progress only. Recovery and cancellation appear only when supported.

**06 · Device.** Show runtime, memory, storage and thermals as readable rows. Keep diagnostics and existing validation sharing accessible. The core overview should fit a common phone at default text size; smaller devices and accessibility text scroll naturally. Unavailable measurements are explicit.

**07 · Lens.** Give the camera or selected image most of the workspace. Keep Ask / Translate / Scan / Solve and native capture/import/switch controls reachable. Use purposeful permission, unavailable, processing and result states. Preserve the host camera session and inference path.

**08 · Voices.** Provide current voice, search, catalog and distinct preview actions. Selection uses a checkmark. Preserve All / English / Multilingual / Cloned as existing catalog filters, without adding cloning. Explain voice readiness and permissions beside the start action.

**09 · Voice conversation.** Show actual session state and transcript when turns exist. The small waveform is informational, not measured amplitude. Keep independent speaker, microphone and end controls. Minimizing preserves the session only when supported and leaves a return action.

**10 · Image studio.** Put the result workspace above a compact next-image dock. Preserve the completed image’s original `imageResultPrompt` separately from editable `imagePrompt`. The dock has a prompt, model choice and Create. No model gives an actionable requirement. Add no unsupported settings. Actual outputs expose existing sharing.

**11 · Settings.** Use a native grouped list. Appearance shows the current value and a native System / Light / Dark menu. Group model, voice and device destinations. Retain saved preferences and omit decorative appearance thumbnails.

**12 · Dark chat.** Retain the same composition with charcoal surfaces, readable assistant prose and quiet user bubbles. Native controls adapt through the system. Verify links, code, attachments, disabled states, keyboard transitions and long text.

## Implementation and verification

The SwiftUI package and Xcode demo are presentation and integration code. The host owns inference, model storage, attachments, durable conversations, permissions, camera and audio. Preserve app identity, entitlements and existing services. The demo labels its sample data; its image is bundled and its `notes.txt` attachment is metadata only.

The generated `composer-content-concept.png` communicates content composition. It is **not a simulator screenshot**. The exact `composer-layout.svg` illustrates app-owned equations. Neither defines native bar geometry, gloss or selection tint. Do not trace native chrome from generated imagery.

This package has not been compiled or rendered with Apple tooling here. Build with Xcode 26+ using `bash Scripts/verify-on-mac.sh`, then build the actual host target. Review small/large phones, light/dark appearance, keyboard transitions, larger text, Reduce Motion, Reduce Transparency and VoiceOver. Exercise real host state and resolve differences in favor of truthful behavior, accessible layout and native control rendering.
