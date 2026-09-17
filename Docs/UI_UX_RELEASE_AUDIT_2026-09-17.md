# OnDevice Max — UI/UX Release Audit

**Date:** 2026-09-17
**Branch:** `ondevice-max`
**Toolchain:** Xcode 27.0 (27A5218g), iOS 27.0 SDK
**Build gate:** `-destination 'generic/platform=iOS'`, Debug, signing disabled — **BUILD SUCCEEDED**

---

## 1. Method, and two constraints that shape everything

Static audit of the SwiftUI view layer plus a compile gate after every change. Findings carry a
count or a `file:line`.

**Several first-pass findings did not survive inspection.** A raw grep says one thing; reading the
call site often says another. Where a headline number turned out to be mostly false positives, it
is corrected in §4 rather than quietly dropped — the corrections are part of the audit.

Two constraints govern release planning:

1. **This app cannot be built or run on the simulator.** `CoreAI.framework` ships only in the
   iphoneos SDK. Every simulator build fails at `ModelStructure.swift:6` (`import CoreAI`).
2. Therefore **no screen here has been visually verified**, and no UI snapshot testing is possible
   in CI. Everything below is code-level. Nothing in this document is a claim about pixels.

---

## 2. Fixed

### 2.1 Release blocker — the app did not compile
`ModelsManagerView.swift` · `CompletedDownloadRow` called `loc.t(...)` without declaring `loc`.
Device builds failed outright. Added the `@ObservedObject` every sibling view uses.

### 2.2 Theme settings did not reach the chat or composer
`Views/Studio/StudioTokens.swift` re-declared the palette as hardcoded hex instead of reading the
injected `KoduTheme`. **OLED mode was visibly broken** — Settings offers it
(`SettingsView.swift:1218`) and paints the page `#010102`, but every Studio surface returned
`#151517`, a lighter slab floating on true black. Rewritten to derive from `theme.*`.

### 2.3 Sub-minimum tap targets in the two most-used control clusters
`StudioGlyphButton` drew and hit-tested the same 34×34 frame — below the 44pt HIG minimum. It backs
the composer's add/camera/snippet/dictate buttons and the answer action row. Now laid out in a 44pt
box with the chip still drawn at 34, plus a negative row inset so the first glyph stays optically
flush with the text above it. Same fix applied to the 12pt trash glyph in
`ModelDownloadCenterView`.

### 2.4 Design-system fragmentation
Three parallel systems (`KoduTheme` 81 files · `StudioTokens` 19 · `AppDesignSystem` 4) collapsed to
one. `AppRadius`, `AssistantSpacing`, `AssistantRadius`, `AppStroke`, `AppShadow`, `AppTypography`
and `KeyboardDismissModifier` all reached zero call sites and were removed.

`GlassRole` carried nine roles; six were unreferenced and two of those held the last `999` pill
radii. Trimmed to the three in use and put on the scale.

`KTactileButtonStyle` and `StudioPressStyle` were near-identical press effects; the former's 5 call
sites were repointed and it was deleted.

**Corner radii: 19 distinct values → 13**, and the app's last literal pill (`cornerRadius: 9999`, on
the Lens composer's send button) is gone. Only ±1pt snaps were applied automatically, so nothing
changed shape class. Remaining spread is in §5.2.

### 2.5 Dead UI removed (~1,300 lines, none reachable)
- The entire `.landing` route in `CodingAssistantView`: `route` initialised to `.chat` and
  `closeChat()` — its only writer — was never called. Nine members plus two status-pill structs.
- `emptyStateView`, `modelLoadBanner`, `capabilityRows`, `suggestions` — defined, never rendered.
- `AssistantComposer` + `AssistantSendButtonStyle` (superseded by `StudioComposer`).
- `FocusBreatheHalo`, `StreamingDots`, `SamplerControlsRow`, `AssistantSuggestionButtonStyle`.
- `Views/GlobalKeyboardBar.swift` — 53 lines, zero references. Removed along with its four
  `project.pbxproj` entries (surgical patch rather than an XcodeGen regen, which would have churned
  a project file already carrying ~3,800 lines of uncommitted diff).

Image generation was verified still reachable from four entry points before the landing came out.

### 2.6 Chat surface
- `ChatThreadEmptyState` rendered **two different design languages from one view** — a flat hairline
  welcome vs. a glass-circle-and-shadow failure state. Unified.
- It received `modelName`/`modelStatus` and rendered neither. Both now appear in the mono eyebrow.
- User turns were inset 18pt while assistant prose, the action row and the empty state used 20pt.
  Unified. The empty state was additionally double-padded (16 + 20 = 36pt).
- Assistant prose had **tighter** line spacing (4) than the user's own text (7.2) — the longest-read
  text in the app was the hardest to read. Both set to 5 (≈1.5× rhythm).

### 2.7 Composer rebuilt
Was flush-to-edge with one hairline and no depth — restrained in intent, unfinished in effect. Now a
contained card: raised fill, hairline that brightens on focus, ambient + contact shadow, weighted
send button with press feedback. All six states preserved, all seven callbacks verified wired,
dictation flow and the `U+001F` recents blob format untouched.

### 2.8 Cold start offered five prompts that could not run
**No language model ships bundled.** On a fresh install the path was: onboarding → Home *"Tap New
chat to start"* → *"What can I help with?"* with five tappable starters → tap one → composer blocked
*"No model loaded yet"*. The welcome screen invited users into a dead end, and the one thing that
had to happen — downloading a multi-gigabyte model — was discoverable only at step four.

`ChatThreadEmptyState` now takes `canGenerate` and leads with the model choice when nothing can
answer, with distinct copy for *"no model yet"* vs *"one is downloading"*.

### 2.9 Destructive actions that destroyed unrecoverable data on one tap
See §4.1 for why the original framing of this finding was wrong. Three real cases, now behind
confirmation dialogs that name what is lost:

- `KnowledgeBaseView.swift:48` — a bare toolbar trash glyph calling `kb.clear()`, wiping **every
  document the user had imported**. Hand-imported files the app never uploads: no copy exists to
  restore from.
- `ModelDownloadCenterView.swift` ×2 — context-menu "Delete model" and a bare trash glyph in the
  card row, both discarding gigabytes recoverable only over the network. `ModelsManagerView:194`
  already confirmed the *same* operation, so it was guarded on one screen and instant on another.

### 2.10 Dynamic Type
Every fixed-size font on **text** converted to the theme helpers, which route through
`Font.custom(_:size:relativeTo:)` — the only way to get an arbitrary point size that still scales.
**37 → 1** (the remaining one is a vendor monogram in a fixed tile with `minimumScaleFactor`).
Fixed-height rows containing text converted to `minHeight` so they grow instead of clipping: 21
sites.

### 2.11 Right-to-left
Arabic is offered in the language menu. The app's language picker is **independent of the system
language**, and SwiftUI derives `layoutDirection` from the *system* locale — so a user on an English
phone selecting Arabic got Arabic text in a left-to-right layout. `effectiveLanguage` (extracted
from the body of `t()`, so one resolution path now serves both) drives `\.layoutDirection` at the
root. Correct for `.system` too, where iOS has already chosen.

### 2.12 Console hygiene
**51 → 0** `print()` calls in shipping code, routed through the existing `Diagnostics` service with
level and category derived per site. The 5 remaining are inside `#if DEBUG`. This matters beyond
tidiness: an app whose core claim is that nothing leaves the device should not narrate prompts and
model paths to the system console.

### 2.13 Reduce Transparency
The four real material surfaces now collapse to an opaque theme fill when the setting is on, via a
shared `adaptiveMaterial` `ShapeStyle` (a `ShapeStyle` rather than a `ViewModifier` so it works as
both a `background` and a shape `fill`).

### 2.14 Naming
`LiquidPinkBackdrop` resolved to a flat `T.studio.paper` across 49 call sites — the page surface was
consistent, the type name just described blurred pink blooms that no longer existed. Renamed
`StudioPageBackground` (52 references, 43 files, plus its project entries).

### 2.15 App icon
Monolithic MAX wordmark — SF Pro Display Black, set tight on a near-black ground with one restrained
sheen. Generated reproducibly by `scripts/make_app_icon.swift` (CoreGraphics + CoreText). Verified
legible at 180/120/80/60pt under an iOS squircle mask.

Writes `AppIcon-1024.png`, `AppIconPreview-256.png` and `AppLogo.png`. **Caught during audit:** the
splash (`PlumDuskSplashView.swift:23`) reads `Image("AppLogo")` whose imageset points at
`AppLogo.png` — writing a differently-named file would have left the splash showing the old eye
while the home screen showed MAX. Alternate-icon machinery intact; "Classic" still selectable.

---

## 3. Open — decisions, not defects

These three are genuine product scope calls. Each is stated with what it would cost.

### 3.1 The redesign covers two tabs; the rest speaks the older dialect
**Colour, appearance and theming are consistent app-wide** — the `K*` components read `koduTheme`,
the same source `StudioTokens` now derives from, so light/dark/OLED behave identically everywhere.
**Component vocabulary is not.**

| Studio | uses | | Kodu `K*` | uses |
|---|---|---|---|---|
| `StudioMonoLabel` | 37 | | `KMono` | 222 |
| Studio controls | ~25 | | `KSection` | 90 |
| | | | `KCaption` | 55 |
| | | | `KRow` | 29 |
| | | | `KStatusBadge` | 23 |
| | | | `KToggle` | 18 |

Assistant and Home are Studio. Models, Settings, Voice and every picker are `K*`. The visible
difference is **shape and rhythm**, not colour: `KSection` draws a bordered card where Studio draws
hairline-separated full-width rows; `KToggle` is a 32×18 pill where `StudioSquareToggle` is a 48×29
square-cut switch.

Converged what was safe: radii onto the scale, the duplicate press style removed.

**Not done, deliberately:** restyling `KSection` from card to hairline rows would change the visual
weight of ~90 sections across the app's largest screens (`ModelsManagerView` 4,425 lines,
`SettingsView` 1,848). Any content relying on the card's inset would run edge-to-edge. That is a
visual redesign, and with no simulator and no device screenshot it cannot be verified — doing it
blind would be guessing, at the scale of the whole settings surface.

**Recommendation:** decide explicitly — either document `K*` as the deliberate
"settings/management" dialect, or schedule the migration with a device in hand.

### 3.2 Translation coverage
14 languages ship at ~290 keys each, but **186 simple `Text("…")` literals never pass through
`loc.t()`** — 159 of them in files with no `loc` reference at all. A German or Japanese user sees
roughly a third of the UI in English.

**Not mass-wrapped, deliberately.** Routing them through `loc.t()` would require adding the
observer to ~40 more structs and would then need 186 keys × 14 languages of translation. Inventing
those is not something to do to a shipping app, and wrapping without them produces 2,600 missing
keys that *look* like progress while changing nothing a user sees. This is content work with a
translator, not a refactor.

The RTL half of this finding **was** a defect and is fixed (§2.11).

### 3.3 Navigation is almost entirely modal
93 `.sheet`/`.fullScreenCover` presentations against 6 `NavigationLink`s, and 100 `show…` state
flags. `CodingAssistantView` alone presents 23 sheets.

No back-breadcrumb, no swipe-back into a hierarchy, and sheet-over-sheet stacking is handled
case-by-case — the code already guards one instance by hand (`ContentView.swift:266`, "so we never
stack sheets"), which is evidence the risk is real. Settings and Models are hierarchical content
presented flat.

Restructuring is an architecture change, not a styling pass. Flagged, not attempted.

### 3.4 iPad unsupported, Catalyst enabled
`TARGETED_DEVICE_FAMILY: "1"` (iPhone only) with `SUPPORTS_MACCATALYST: YES`. Only 12 size-class /
idiom checks exist, so the Catalyst build is an iPhone layout stretched to a Mac window. Confirm
Catalyst is a shipping target; if yes it needs its own pass, if no drop it from scope.

---

## 4. Corrections to the first pass

### 4.1 "43 destructive actions, 18 confirmations" — wrong inference
The ratio implied a gap. It did not exist as stated: many of the 43 `role: .destructive` buttons
**are** the confirm button inside a dialog, and many of the rest only *open* one. Brace-matched
against enclosing `.alert`/`.confirmationDialog` closures, then hand-checked:

| Category | Count | Verdict |
|---|---|---|
| The confirm button inside a dialog | 12 | correct by construction |
| A button that *opens* a confirmation | ~9 | correct |
| Swipe / context-menu, single item | ~5 | proportionate — iOS convention |
| Clears a log, resets a setting, cancels a download | ~14 | proportionate |
| **Destroyed unrecoverable data on one tap** | **3** | fixed (§2.9) |

Both highest-stakes operations — wipe-all-data and delete-model in `ModelsManagerView` — were
already correctly gated.

### 4.2 "360 fixed-size fonts, 193 fixed-height rows" — mostly false positives
**322 of the 360 are on SF Symbols**, where a fixed point size is the normal, correct pattern;
scaling them breaks fixed-size button geometry. Only 37 were on text. Likewise **303 of the 330
fixed heights are decorative** — progress bars, dots, spacers, icon frames. Only 27 were text rows.
The real sets were tractable and are fixed (§2.10).

### 4.3 "Arabic will render incorrectly, every layout is hardcoded LTR" — wrong
There are **zero** `alignment: .left/.right` and **zero** `.padding(.left/.right)` in the codebase;
it uses `.leading`/`.trailing` throughout (512 uses), which SwiftUI mirrors automatically. The real
defect was narrower and different — the in-app picker not driving `layoutDirection` — and is fixed
(§2.11). Residual risk is 7 manual `.offset(x:)` calls, which do not mirror.

### 4.4 "Reduce Transparency honored in exactly one file" — misleading
`GlassEffects` renders flat fills and hairlines, not materials, despite the historical
`glass`/`kGlass` names — so the ~200 call sites routing through it were never a transparency
problem. Only 4 real material surfaces existed. Fixed (§2.13).

### 4.5 "13 view files don't read the theme; 37 hardcoded white/black" — mostly correct-as-is
The theme-less files are `UIViewControllerRepresentable` wrappers around system pickers (document
scanner, photo picker, QR scanner), `#if DEBUG` files, and the splash. The white/black uses are over
the camera feed (always dark), on filled accent buttons (correct pairing), or shadow/scrim colours.
Two genuinely wrong dividers in `AnalysisPanelView` were themed; the rest are right.

---

## 5. Remaining, low

### 5.1 Undo
`ToastCenter` has 96 call sites and is the natural home for undo-with-delay, which would suit the
log/history clears better than either a dialog or nothing. Needs a deferred-commit API that does not
exist yet.

### 5.2 Radius spread
`10`×130 · `6`×107 · `8`×44 · `12`×37 · `14`×28 · `3`×20 · `16`×19 · `4`×18 · `22`×15 · `20`×8 ·
`18`×8 · `24`×1 · `15`×1.

The remaining merges (8→10, 12→10/14, 16→14, 18/22→20, 24→26) are ±2–4pt. At that magnitude a radius
can be half its own frame, and snapping it turns a circle into a rounded square — these need
per-site eyes, not a regex.

### 5.3 Haptics
234 `HapticManager.impact` calls against 227 `Button {`. Roughly universal but not systematic — some
buttons fire twice (style + action), some not at all.

---

## 6. Release readiness

| Area | Status |
|---|---|
| Compiles (device) | ✅ fixed — was failing |
| Visual verification | ⛔ **impossible without a signed device install** |
| Automated UI testing | ⛔ blocked — simulator cannot build this app |
| Colour / theming consistency | ✅ one token system |
| Component consistency | ⚠️ §3.1 — two dialects, by decision |
| First-run flow | ✅ dead end removed; unverified on device |
| Functional regressions | ✅ none found; entry points re-verified by grep |
| Dynamic Type | ✅ text scales; 1 deliberate exception |
| Right-to-left | ✅ fixed |
| Translation coverage | ⚠️ §3.2 — ~66%, content work |
| Destructive actions | ✅ 3 real gaps closed |
| Tap targets | ✅ primary clusters; unaudited elsewhere |
| Console hygiene | ✅ 51 → 0 shipping |
| Navigation model | ⚠️ §3.3 — architectural |

### Gate before submission
1. **Install on a device and walk the cold-start path end to end** — fresh install → legal →
   onboarding → Home → Assistant with no model → choose → download → first answer. Every new user
   takes this path, it changed in §2.8, and it has never been seen running.
2. **Walk the Assistant tab in all three appearances.** OLED was broken before this pass (§2.2).
3. Decide §3.1 and §3.4.
4. Plan §3.2 with a translator.

---

## 7. Not covered

Performance, memory under model load, MLX/GGUF runtime behaviour, network/bridge security, the Lens
camera pipeline. Within UX: copy tone across the whole app, the Lens and Voice tabs as flows, and
VoiceOver rotor/traversal order — the last needs a device and a real screen-reader session, not a
code read.

No claim is made about how any screen looks. See §1.
