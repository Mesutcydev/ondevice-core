# UI consistency audit — 2026-09-19

> Historical audit of the previous design. Current integration and executed simulator checks are recorded in [NATIVE_UI_IMPLEMENTATION.md](NATIVE_UI_IMPLEMENTATION.md). Do not use this audit's former styling as the design source.

Scope: the whole app as it now ships — the `OnDeviceUI` package shell plus every
screen reachable from it. Two static audits (layout conflicts; control
proportions) plus a routing audit of `ODBridge`, all verified by reading the
sources. No simulator run was possible (CoreAI is device-only), so nothing here
claims a pixel result.

## Fixed in this pass

### Buttons that could not do anything

Every one of these called an `ODBridge` route whose whole body was
`selectedTab = .models` — from the Models tab, nothing happened.

| Where | Was | Now |
| --- | --- | --- |
| `ODModelsView` "Find your next model" | tab switch | `HFSearchView` sheet |
| `ODModelsView` "Core AI packs" | tab switch | `CoreAIModelsSectionView` in a titled sheet |
| `ODModelsView` "Manage" (storage) | tab switch | `ModelStorageCleanupView` sheet |
| Model row / "View model" / menu → Details | tab switch | `ModelDownloadCenterView` |
| Menu → Configure | tab switch | `AssistantModelSettingsView` |
| Menu → Export to Files | tab switch | `LocalModelExportPicker` |
| Menu → **Delete** (already confirmed) | tab switch | `ModelDownloadCenter.handleDeletion(of:)` |
| `ODLensView` camera flip | dimmed dead button | slot rendered empty (keeps the shutter centred) |
| `ODVoiceSessionView` audio route | chevron-down pill that never opened | reading: glyph + route name, no button |
| Lens shutter with no vision model | enabled, failed downstream | `caps.canCapture` now requires a vision model |

### Duplicate destinations

- `CodingAssistantView`: "Past conversations" existed as both a toolbar glyph
  and an overflow-menu item → menu copy removed.
- `ODModelsView`: the ellipsis menu repeated `Details`, which the row itself
  opens → filtered out of the menu.

### Two screens inset and padded for the same clearance

- `OnboardingOnePager`: `.padding(.bottom, 140)` (written for the old hand-built
  tab bar) on top of its own bottom-inset CTA bar → `StudioSpacing.xxl`.
- `ModelStorageCleanupView`: 96pt tail inside the scroll plus its own
  bottom-inset action bar → `StudioSpacing.xxl`.

### Tap targets below 44pt (all now 44pt)

`StudioComposer` attachment-remove badges (18pt), `HFSearchView` open-link and
expand-row (34pt), `BridgePairingView` model-picker ellipsis (30pt),
`KnowledgeBaseView` remove-document (a bare 13pt glyph, no frame at all),
`MicDictationButton` (36pt), `ModelDownloadCenterView` "auto-find" pill (~24pt
tall), `HFTokenSheet` "Test" pill (~24pt), `VoiceControlDeck` route control and
test-audio (28pt), `AudioRoutePicker` (28pt), `ODKeyboardDismissKey` (36pt).

### Radii off the ladder

- `StudioComposer` status strip: literal 18 → `StudioRadius.sheet`.
- `StudioComposer` badge corners: literal 5 → new `StudioRadius.badge` token
  (an 18pt badge cannot carry the 8pt step without reading as a blob, so it is
  named rather than inlined).
- `VoiceControlDeck` rail: literal 28 → `StudioRadius.composer`.
- `ODSuggestionChip`: `ODRadius.field` → `ODRadius.chip`.

## Closed in the follow-up pass

- **Dead old shell deleted.** `ContentView` carried the whole old Lens tab:
  `CameraRootView` plus `LensModelStatusIndicator`, `LensScanFrame`,
  `LensPromptComposer`, `ScanCornersShape`, `CaptureAura`,
  `StreamingGradientEdge`, `CaptionSkeleton` and `FocusReticle` — nothing
  instantiated any of them. Removed by brace-matched deletion; the file went
  2434 → 748 lines. `LensMode` and `StreamSafeTextSelection` are still live and
  were kept.
- **Nested share sheet removed.** `ConversationPickerView` exports a
  conversation by writing a temp file and now *hands it to the chat*, which
  dismisses the picker and presents one share sheet from its own level
  (`AssistantSharePayload` gained `fileURL` + `shareItems`). No sheet is
  presented from inside a sheet by this path any more.
- **One "choose a model" affordance per screen.** With an empty thread and no
  model loaded, the composer's blocked row now states the situation without a
  second button — the empty state's CTA is the action. The composer gained
  `hidesChooseModelAction` (default false, so no other call site changed).
- **Duplicate import sheet removed** from `ModelsManagerView` (the page-body
  copy is the one its own comment calls authoritative).
- **`StudioSpacing.tabBarClearance` corrected: 140 → 24**, with the doc comment
  explaining that a native `TabView` already reserves the bar (~82pt measured),
  so the old value left a third of a screen of empty paper. This also fixes both
  files below if they are ever re-wired.
- **One switch, not two.** `KToggle` was a byte-identical second copy of
  `StudioSquareToggle` whose only difference was the accessibility traits; the
  traits moved onto the original and `KToggle` is now a typealias.
- **`kGlassCapsule`** comment now says what it actually draws (chip radius under
  a capsule role).

## Open — deliberate, not forgotten

1. **`ModelsManagerView.swift`, `VoiceLibraryView.swift`,
   `AnalysisPanelView.swift` compile but nothing instantiates them.** They are
   *not* deleted: each still holds real behaviour (set-as-default, per-model
   export, the HF token sheet, voice engine selection, the old analysis result
   panel) and re-wiring them is a product decision. Each file now opens with a
   status header saying exactly that, and how to remove it
   (delete + `xcodegen generate`). Recommended: decide per file.
2. **`ModelsManagerView.swift:177` still has `StudioSpacing.tabBarClearance`**,
   which is now correct — no action needed if it returns to a tab page.
3. **Cosmetic, left alone on purpose:** the package mixes `Capsule()` badges and
   filter underlines (`ODVoiceSessionView`, `ODChatView`, `ODModelsView`,
   `ODSystemView`, `ODVoiceLibraryView`, `ODLensView`) with rounded-rect
   surfaces. That is the handoff's own language for badges; changing it is churn
   without a functional gain.
4. **Two stacked-modal candidates remain elsewhere** (not touched here):
   `SettingsView` and `AssistantModelPickerView` each present a sheet from
   inside themselves (model settings, import). They are one layer deep and were
   not part of the reported bug; re-check them if a "sheet won't dismiss"
   report ever arrives.


### Side effect of deleting the old Lens tab (checked, no regression)

`DocumentScannerView`, `CodeModeView`, `MarkupCanvasView`, `AnalysisHistoryView`,
`LensDebugOverlayView` and `LiveOCROverlayView` were only ever presented from `CameraRootView`, so
they now have no entry point at all. They had none before the deletion either —
`CameraRootView` was itself unreferenced — so nothing regressed; but if any of
them is wanted, it needs a real entry point (the chat menu's "Scan document" /
"Code mode" items are the obvious candidates). Their files are untouched.

## Verification

Compile-verified only, step by step, after each checkpoint:
`xcodebuild -workspace OnDeviceMax.xcworkspace -scheme OnDeviceMax
-configuration Debug -destination 'generic/platform=iOS'
CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED with 0 errors after every step
(logs `/tmp/build_ck1.log`, `/tmp/build_ck2.log`, `/tmp/build_ck3.log`). The app
cannot be run in a simulator (CoreAI is device-only), so no pixel claim is made
for any host screen.
