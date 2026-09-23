# Home direction review — 19 September 2026

The user rejected the build-40 home and requested three different visual options.
These are review-only SwiftUI screens in `HomeConcepts.swift`; no direction has
been selected or connected to the production app.

Launch NativeUIReview using `-screen home-concept -dark -home-variant <name>`:

- `focus` — one starting space, three actions, one continuation shortcut.
- `tools` — four destinations: Write, Documents, Images, Code.
- `library` — conversation search, last-opened preview, earlier conversations.

All three use the package's real composer and native TabView. Conversation
examples are illustrative fixture content. Preview-only actions are labeled
as previews rather than pretending to run inference or import a document.

Validation: NativeUIReview built successfully for iPhone 17 on iOS 27; each
direction was captured and visually inspected. Focus and Library spacing was
tightened after checking the composer boundary. Three distinct screenshots were
staged in Argent Lens. The inline comparison's three tabs were checked in a
browser. The user's direction can be selected by replying 1, 2, or 3 in chat.

Inline comparison and durable preview PNGs:
`/Users/m/.codex/visualizations/2026/09/19/01a0b947-dcc6-79b2-83c9-5d140a08f1b0/`

No new IPA was produced for this concept review.
