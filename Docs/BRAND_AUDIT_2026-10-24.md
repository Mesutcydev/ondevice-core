# Token AI brand and design audit — 2026-10-24

The icon and App Store artwork have a strong identity: a white stepped
waveform on near-black ink, set beside a bold sans "Token AI". Before this
pass, the app itself used none of it. The UI was white surfaces, gray type and
two unrelated iOS blues, so it read as a generic template. That is why it
looked pale. Shipped in 2.0 (73).

Evidence: `build/brand-audit/shots/{before,after,final,onboarding}` (QA/NativeUI
host, iPhone 17 Pro Max simulator; ignored by Git). UI flows
`testSettingsAppearanceAndOnboardingRender` and
`testSidebarDarkOLEDAndAccessibleControls` pass.

## Findings and fixes

| # | Finding | Fix |
| --- | --- | --- |
| 1 | No logo anywhere in the app | `ODBrandMark` / `ODBrandTile`: a vector trace of the icon (`Components/ODBrandMark.swift`). Shown in the sidebar header, splash, onboarding and New chat |
| 2 | Generic motion: three gray dots and about 15 `ProgressView` spinners | Live mark: a highlight streams along the steps for reasoning/waiting, Preparing model, Responding rows, Image studio, Lens analyzing and System preparing. Determinate download bars kept |
| 3 | Model picker dot was static gray | Gray idle, green when the model is loaded, pulsing green while generating |
| 4 | Three wordmark styles (serif ×2, SF bold) vs a bold sans in the artwork | Bold sans everywhere; unused serif `ODWordmark` deleted |
| 5 | Home-screen name `Token: Local AI Studio` truncates to "Token: Local…" | `CFBundleDisplayName` = **Token AI**. "Token: Local AI Studio" stays the App Store name |
| 6 | Accent was iOS blue `#007AFF`, and app `AccentColor` a different blue `#1D4ED8` | Both now ink (`#1C1C1E` light / `#F5F5F7` dark), matching the host theme. The two remaining untinted prominent buttons use `odInkProminent()` |
| 7 | Small gray type felt washed out | `ODSecondary` firmed to `#505054` / `#BDBDC2` (8:1 on white) |
| 8 | Model vendor badges were multicolour gradients and an emoji | White letters on the icon's ink plate |
| 9 | Splash: serif text on white; launch screen white | Splash and `LaunchBackground` both use the icon's ink. The mark traces in, then streams (1.6 s hold) |
| 10 | Onboarding: one generic page with a serif title | Four pages (Welcome, Runtimes, 35B models, Studio) built from app components, translated into all six required languages |
| 11 | Light canvas, surface and chrome are all `#FFFFFF` | Kept for the chat canvas, as in standard chat apps. Depth comes from the grouped sidebar, Settings and onboarding surfaces |

All motion stops with Reduce Motion, and while the workspace or app is not
visible (the same `TimelineView` gating as the caret).

## Onboarding content source

The model facts come from the catalogs, so the copy stays accurate:

- Edge0-35B A3B Preview (`AssistantModelCatalog`): 4-bit, 19.6 GB, experts
  streamed from disk.
- MiniCPM-V 4.7 35B A3B (`MiniCPMV47Catalog`): experimental, needs 12 GB RAM
  and about 35 GB free.

Both are in `AuditedModelRevisions.json`, and the `ODMiniCPM` streaming runtime
is linked into release builds.

## Remaining

- App Store screenshots still show the pre-logo UI. Recapture with the
  QA host after this build is approved, before replacing the live set.

## Using the mark

```swift
ODBrandMark(height: 10, motion: .live)   // activity; inherits foregroundStyle
ODBrandMark(height: 22, motion: .drawOn) // one-time reveal
ODBrandMark(height: 44, motion: .intro)  // reveal, then stream (splash)
ODBrandTile(size: 34)                    // app-icon lockup
```

The geometry is traced from `AppIcon-1024.png` (704×234 bounds, 37-pt stroke).
If the icon changes, re-trace the points in `ODBrandMarkShape`.
