# UI design audit — 2026-09-20 (Downloads / Image studio / API server)

Triggered by three device screenshots (dark mode, iPhone 17 Pro Max) flagged as
"undesigned, low quality". This audit records what looked wrong, what was
changed in this pass, and what is recommended next. Verification: QA/NativeUI
harness compile + 3/3 API workspace tests + 6/6 Round 2 flow tests, simulator
screenshots of both native screens, and a full device-target compile of the
app (`** BUILD SUCCEEDED **`).

## 1. Downloads sheet (`ModelDownloadCenterView`) — largest gap

**Before (device screenshot):** the screen still spoke the retired pre-native
dialect — all-lowercase labels (`storage`, `ram`, `source`, `download`,
`this iphone · max tier`), monospaced body copy on cards, and a heavy inverted
white "download" slab as the primary action. Next to the native Image studio
and API server surfaces it read as a different, older app.

**Changed in this pass (presentation only — every action, sheet, confirmation
dialog, observer and haptic is untouched):**

- Storage header: sentence-case labels (`Storage` / `Memory` / `Source`).
- Category selector: label size 11 → 13 for optical balance with the icons.
- Device tier line: "This iPhone · Max tier · 12.26 GB RAM", sans footnote
  instead of tracked mono.
- Search/discovery rows: sans 15 medium titles, sans 12 subtitles, title case
  ("Recommended for Max tier", "Search all models", …).
- Guarantees footer: title case, sans semibold labels ("Privacy",
  "Resumable downloads").
- Model cards: human one-liner now sans 13 (mono is reserved for the repo-id
  meta line, which is genuinely technical); meta line 9.5 → 11 for legibility.
- **Primary action**: the inverted white slab is now an accent-blue capsule
  ("Download" / "Retry"), matching the blue-primary grammar of the other
  native surfaces. Pause is a warn-tinted capsule; recovery pills ("Auto-find",
  "Find repo") and the "Ready to use" badge are title case, sans.
- Failure/preparing readouts: sans, ≥12 pt.

**Not verifiable in the simulator:** this view is not part of the QA/NativeUI
harness, so it was compile-gated only (full app device build passed). Check it
once on the physical device — in particular card density at Accessibility
text sizes and the blue capsule against both light and dark themes.

**Recommended next:** give `mlx-community` a real two-letter monogram ("Mx")
instead of the bare "x" glyph tile, and consider moving the sheet to a
large-title navigation bar with an inline search field instead of the custom
selector header.

## 2. Image studio (`ImageGenerationView` + `ODImagePromptSuggestions`)

**Before:** with no model installed, the page was a title, three bare text
rows, and ~60% dead black space above the composer — the void read as
unfinished rather than empty.

**Changed in this pass:**

- New `emptyCanvas` placeholder occupying the exact slot where the generated
  image lands: photo symbol, "Your image will appear here", hairline-stroked
  rounded panel. The middle of the page now has structure, and the placeholder
  pre-teaches where output appears (spatial consistency).
- Prompt suggestions are now one grouped card (inset dividers, secondary
  return-arrow glyphs) instead of three floating rows with full-bleed
  hairlines — same visual family as the API server's grouped sections.

**Verified by screenshot** (`build/design-polish/after-image-empty-dark.png`,
dark) and by the Round 2 flow tests that exercise these rows.

**Recommended next:** a fixed 260 pt canvas height should become
`min(280, 34% of viewport)`-style adaptive sizing so small phones and
Accessibility text sizes keep the suggestions above the fold; the "Create"
button could mirror the composer's accent treatment for consistency.

## 3. API server (`LocalAPIServerView`)

**Before:** structurally fine (native grouped form) but every state read as
identical gray text — "Stopped", "Not loaded", "Running" carried no glanceable
signal.

**Changed in this pass:**

- Server status value is color-coded (green running / orange starting / red
  failed / secondary stopped); the model section status is color-coded the
  same way (green "Ready for API requests", …). The status **text** is
  unchanged and remains the VoiceOver/QA source of truth — the
  `api.status` accessibility contract is preserved and its tests pass.
- Port field uses monospaced digits.

**Verified by screenshot** (`build/design-polish/after-api-dark.png`) and 3/3
`APIServerWorkspaceTests`.

**Recommended next:** when the server is running, the Connection URLs section
would benefit from per-row copy affordances styled as bordered buttons rather
than full-width text rows, and a small green status dot in the section header
while running.

## Cross-screen recommendations (not done in this pass)

1. **Retire remaining mono-body screens.** `KMono` now has a `mono: false`
   escape hatch; audit remaining call sites (e.g. `ModelStorageCleanupView`,
   older Settings rows) and keep mono only for ids, shapes, tok/s and numeric
   readouts.
2. **One primary-action definition.** Blue capsule (Downloads), blue glass
   prominent (Image studio) and blue text buttons (API server) are three
   shades of "primary". Pick one per prominence level and codify it in
   OnDeviceUI so future screens don't re-invent it.
3. **Light-mode pass.** This audit worked dark-only, matching the report.
   The changed surfaces use theme/adaptive colors, but eyeball one light-mode
   screenshot per screen before the next tag.
4. **Vendor monogram tiles.** Neutral tiles with single lowercase letters
   read as placeholders ("x"); a curated monogram map for the top vendors
   would make the catalog feel authored.

## Evidence

- Before: the three attached device screenshots (copied to
  `build/design-polish/shot-1..3.png`).
- After: `build/design-polish/after-image-empty-dark.png`,
  `build/design-polish/after-api-dark.png`.
- Tests: `build/design-polish/qa-api-tests.log` (3/3),
  `build/design-polish/qa-round2-tests.log` (6/6),
  `build/design-polish/app-build.log` (device build succeeded).

## Ships in

Sideload build 46 (`OnDeviceMax-sideload-entitled-1.0.0-46.ipa`, 46,293,226
bytes, SHA-256 `1bcbd7d164bd4c98426a4b51ca8716847056675ef54b7236bd4d59135973629c`).
All eight release stages passed (`build/release-46.log`); independent
verification (`build/releases/OnDeviceMax-46-verification.json`) confirms the
bundle identity and exact app/share-extension entitlement dictionaries.
Profile-less — installer-side re-signing required. The Downloads-sheet
restyle is compile-gated but has not been eyeballed on a physical device yet.
