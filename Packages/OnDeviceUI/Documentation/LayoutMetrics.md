# Layout metrics

The latest 19 September mobile reference uses native glass, a model pill and blue Voice/Send/Stop control. Image attachments have 96-point previews (112 at accessibility sizes), with independent 44-point removal targets. This supersedes the original 24-point composer radius; the writing-area equations remain unchanged.

The chat composer is one app-owned panel: draft attachments, writing area, then a separate control footer. Its structure follows the reviewed official Codex desktop composer, adapted to OnDevice's supported local-model and attachment actions. This document defines its dimensions and responsive equations without assigning geometry to Apple's native navigation or tab bars.

`Sources/OnDeviceUI/Theme/ODTheme.swift` defines the shared `ODLayout` constants and helpers. SwiftUI measures the actual text and native buttons. The layout accepts those measurements; it does not force controls into predicted dimensions.

## Content scale

All dimensions below are logical points. The spacing unit is **u = 4 pt**. These values are explicit app design choices, not evidence that a particular ratio proves a design is better.

| App-owned value | Equation | Value |
| --- | --- | ---: |
| Page inset, G | 5u | 20 pt |
| Gap between message groups | 6u | 24 pt |
| Gap between related elements | 2u | 8 pt |
| User bubble horizontal padding | 4u per side | 16 pt |
| User bubble vertical padding | 3u per side | 12 pt |
| User bubble corner radius | 5u | 20 pt |
| Minimum interactive target | 11u | 44 pt |
| Composer panel radius | fixed | 26 pt |
| Composer panel horizontal inset | 3u per side | 12 pt |
| Additional writing-area horizontal inset | u per side | 4 pt |
| Writing-area total horizontal inset | 3u + u per side | 16 pt |
| Panel top inset | 2u | 8 pt |
| Writing-area minimum height | 11u | 44 pt |
| Gap before control footer | u | 4 pt |
| Footer minimum height | 11u | 44 pt |
| Panel bottom inset | 2u | 8 pt |
| Panel minimum height, no attachments | 8 + 44 + 4 + 44 + 8 | 108 pt |
| Content action glyph at base text size | 5u | 20 pt |

The composer and message bubbles are app content surfaces. Their radii do not set the shape of a native button, tab bar or toolbar. Native buttons use Apple's APIs and preserve their actual intrinsic sizing. A 44 pt target is a minimum; native styling, localization and Dynamic Type may require more room.

The same scale applies to shared app components: standard search rows use a `12u = 48 pt` minimum, compact section containers use a `7u = 28 pt` minimum, label gaps are `3u = 12 pt`, and grouped content defaults to `4u = 16 pt` padding. Shared buttons and search controls inherit these tokens rather than unrelated per-screen spacing. These are content minimums, not fixed font line heights. Semantic fonts and native control padding are allowed to fall between grid values. One-pixel separators, animation durations and state opacity are not spacing units.

## Panel width

Let **W** be the horizontal width available inside the system safe area. With **G = 20**, the transcript and composer panel use the content width:

`C = max(0, W − 2G)`

The writing area is above the controls, so its width does not lose space to a side-by-side attachment or Send button. The footer has its own flexible horizontal layout.

For an illustrative **W = 393 pt**, using the declared app insets:

| Region | Calculation | Width |
| --- | --- | ---: |
| Transcript / outer composer panel | 393 − 2 × 20 | 353 pt |
| Footer layout area | 353 − 2 × 12 | 329 pt |
| Writing-area layout region | 353 − 2 × (12 + 4) | 321 pt |

These figures describe app-owned layout regions at the example width. They are not measurements of native button rendering, glyph bounds, text-field internals or a particular iPhone's current safe area.

The regular footer has four children when Voice is supported: Add attachment, the flexible model menu, Voice, and Send / Stop. It uses an 8 pt gap between children and no extra Spacer. Let **I = C − 24** be footer width; **A**, **V** and **S** are the actual measured widths of the attachment, voice and send controls after their minimum targets and native styling. For a fitting horizontal footer, the model region is:

`M = I − A − V − S − 3 × 8` when Voice is present.

`M = I − A − S − 2 × 8` when Voice is absent.

At the example **I = 329 pt**, assuming the minimum-target case **A = V = S = 44 pt**, the model region is **173 pt** with Voice and **225 pt** without it. These are conditional calculations, not measured native button sizes. The model menu retains its own 44 pt minimum target; actual native widths and text metrics govern the final allocation. Long model names must not reduce action targets to preserve the illustrative number.

At accessibility text sizes, the model control occupies a row above the icon action row. That footer contributes its full measured height, including row spacing, to the panel. Native control sizes remain unconstrained by a fixed toolbar height.

## Panel height

Let **T** be the writing area's measured natural height and **F** the footer's measured natural height, excluding the panel's explicit padding. For no attachments:

`H = 8 + max(44, T) + 4 + max(44, F) + 8`

The lower bound is therefore **108 pt**. This is a minimum content equation, not a prediction that every device renders a 108 pt panel. If the measured footer is 50 pt and the text region stays within its 44 pt minimum, the equation produces 114 pt. The panel accepts the larger native measurement. One ordinary attachment row is **108 + 44 + 4 = 156 pt**.

When attachments are present, let **A** be the measured strip height. The strip is inside the panel above the writing area, and adds one 4 pt gap:

`H_with_attachments = H + A + 4`

The accessibility footer uses the same equation: **F** is the full stacked footer height. There is no fixed extra allowance that assumes native model text or action controls have a known height.

The implementation uses natural SwiftUI stacks and minimum frames. `composerPanelHeight(textNaturalHeight:footerNaturalHeight:attachmentStripHeight:)` records the calculation for review or integration; it is not used to override Apple's measurements with guessed values.

## Typography and draft behavior

Messages and draft text use semantic `.body` fonts. Secondary model information and filenames use semantic text styles; the wordmark uses `.largeTitle` or `.title` with a serif design. Content action glyphs begin at 20 pt and scale through `@ScaledMetric(relativeTo: .body)`. SwiftUI supplies actual font metrics and Dynamic Type growth. Native tab-bar and navigation typography is left to the system.

The multiline field supports **one through six visible lines**. Return inserts a newline; there is no submit-to-send callback. Sending is an explicit action. Whitespace is inspected only to detect an empty draft; submission preserves the user's exact text, including code indentation and intentional newlines.

Attachments display metadata chips with a file or image symbol, filename and separate Remove action. The filename region is capped at `40u = 160 pt` and truncates in the middle. The strip does not decode images, inspect files or invent upload progress. Each Remove action retains a 44 pt minimum target and may grow with its native layout.

Attachment IDs belong to the host. Remove sends an intent and the host acknowledges it by updating the list. Attached submissions carry an immutable snapshot of attachment IDs and require `canSendAttachments` plus normal model and messaging readiness. The host clears only the acknowledged draft version so newer edits are preserved. Text-only submissions retain their original intent.

## Message width and physical pixels

A user bubble may occupy at most 82% of content width. This is a readability and alignment choice, not an Apple requirement or a scientific result. Assistant prose uses the available content width.

With display scale **s**:

`floorPixel(x, s) = floor(max(0, x) × max(1, s)) / max(1, s)`

`maximumUserBubbleWidth = floorPixel(0.82 × C, s)`

For **C = 353 pt** and **s = 3**, the cap is `floor(289.46 × 3) / 3 = 289⅓ pt`. Short messages may be narrower. The maximum interior text region is the bubble cap less 32 pt of horizontal padding. Hairlines use one physical pixel, `1 / s`; focused search decoration uses two pixels.

## Native system boundaries

The composer is attached through `safeAreaInset(edge: .bottom)` inside the chat destination. The operating system's navigation, tabs, keyboard and device safe areas determine its vertical position. The package uses the real `TabView`, `NavigationStack` and native iOS 26 button APIs. It supplies no native bar height, tab radius, blur, material or selected-item tint. No replacement tab bar is drawn or hidden. See [Apple's TabView documentation](https://developer.apple.com/documentation/swiftui/tabview) and [Apple's SwiftUI design session](https://developer.apple.com/videos/play/wwdc2025/323/).

The conversation drawer is an app content pane with width `min(0.88 × W, 100u)`; it does not replace a system navigation bar. The empty-chat readable column is capped at `130u = 520 pt` on wider layouts. Neither rule reduces native control sizes.

Verify actual typography, control sizes, attachment scrolling, keyboard transitions and accessibility layouts in Xcode 26 or newer on an iOS 26 simulator or device. Source review confirms the declared equations and native API use; it cannot establish rendered Liquid Glass geometry or runtime font measurements.
