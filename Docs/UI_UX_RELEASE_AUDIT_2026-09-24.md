# UI / UX release audit — build 59 — 24 September 2026

Scope: the build 59 candidate (`OnDeviceMax-sideload-entitled-1.0.0-59.ipa`,
archived 2026-09-24 02:17). No UI source file is newer than that IPA, so the
working tree is the build 59 source. The audit covers the `OnDeviceWorkbench`
shell, every primary workspace, Settings, first run, accessibility, localization,
copy and visual consistency.

Method:

- **Static review** of `Packages/OnDeviceUI` (5,078 lines) and `IOSLocalLLM/Views`
  (~35,000 lines), plus pattern sweeps: contrast, fonts, labels, motion,
  localization, destructive actions and navigation.
- **Visual pass** in the `QA/NativeUI` review host, rebuilt fresh for this
  audit (`build/audit-ux/build.log`). Tested on the iPhone 17 Pro Max iOS 27
  simulator in light, dark and accessibility-5 text sizes. Screens: Chats,
  drawer, Models (Installed/Discover), Lens, Voice, Device, API server, Image
  studio, Settings fixture, Onboarding and the composer. Evidence is in
  `build/audit-ux/shots/`.
- The production app is device-only (Core AI), so production Settings, the
  chat transcript and every sheet were reviewed only as source code. The
  review host uses fixtures, not real inference.

## Verdict

**Not release-ready.** The UI is mostly coherent and native, with good
accessibility labelling: an automated sweep found no unlabeled icon-only
button. Six P1 issues remain. Two affect core content: code renders in a
proportional font, and the primary Download action is illegible in dark
mode. Two affect reach: the new shell is not localized, and VoiceOver can
likely reach hidden screens. Two affect activation and feedback: first run
has no path to a first model, and errors are silent for VoiceOver users.

The process gates from the [build 52 audit](RELEASE_AUDIT_BUILD52_2026-09-23.md)
are still open. Builds 56–59 are uncommitted: `HEAD` is the build 55
baseline, and 73 modified files plus untracked sources sit on top of it.
`CHANGELOG.md` stops at build 52. The hardware gate also remains open.

Severity: **P1** fix before release · **P2** should fix · **P3** polish.

## P1 — fix before release

| # | Finding | Evidence | Fix |
| --- | --- | --- | --- |
| 1 | **Code renders in a proportional font.** `KoduTheme.mono(_:)` returns `.system(textStyle)`, which is SF Pro, not monospaced. Chat code blocks, `CodePanelView`, API keys and URLs all misalign indentation and columns. This is the core content of a coding assistant. | `Models/KoduTheme.swift:317`; `CodingAssistantView.swift:5251`; `CodePanelView.swift:66` | Return `.system(textStyle, design: .monospaced)`. Dynamic Type still scales. This is a one-line fix. |
| 2 | **Download button illegible in dark mode.** It draws white text on `ODAccent`. The dark accent is `#A1C3FF`, so contrast is **1.78:1** against a 4.5:1 minimum. This is the primary action of Discover. | `ODModelsView.swift:489-495` | Use `ODPalette.onSend` on `ODPalette.send`, as the other primary buttons do, or `.buttonStyle(.glassProminent)`. |
| 3 | **The new shell is not localized.** Settings offers 15 languages through `loc.t()`, about 290 keys each. `OnDeviceUI` has **153 English literals and no strings table**. This covers the sidebar, Chats, Models, Lens, Voice, the composer and confirmations. With the language set to Turkish, only the host menus translate. The prior audit's §3.2 gap has grown. | `grep -c 'loc\.t' Packages/OnDeviceUI` = 0 | Either ship a String Catalog for the package (`defaultLocalization` + `.xcstrings`) or restrict the picker to fully translated languages until then. |
| 4 | **VoiceOver can likely reach invisible workspaces.** Retained workspaces are hidden with `opacity(0)` + `accessibilityHidden`. In the AX tree, the Chats rows (`home.conversation.*`) stay exposed while Models is on screen. The workspace also stays exposed behind the open drawer. The team hit the same issue with voice controls (see `QA_LOOP_HANDOFF.md`, "opacity/accessibilityHidden alone exposed duplicate voice controls"). | `ODWorkbench.swift:146-160`, `:142`; ax-service dumps | Gate the retained content on `odWorkspaceVisible`, or use `.hidden()` with a state-preserving container. Verify with VoiceOver on the device. |
| 5 | **First run has no route to a working chat.** The path is: legal gate (four documents, each read to the end), then one onboarding page ("Get started"), then an empty Chats screen with no model. From there: New chat → "Choose model" → picker filtered to *downloaded* models → "No chat models installed" → Browse Models → Models → Discover → Download. That is about 10 steps before a first message, and no step recommends a model. `OnboardingModelPickerView` exists but is reachable only from Settings. | `ContentView.swift:360-374`; `OnboardingOnePager.swift`; `AssistantModelPickerView.swift:273-285`; `LegalAcceptanceView.swift:39` | Add a "Recommended model for this iPhone" step (reuse `OnboardingModelPickerView` + `DeviceTierAdvisor`) to onboarding. Deciding to merge the four legal documents into one acceptance with links is a product/legal call. |
| 6 | **Errors are silent for VoiceOver users.** `ToastCenter` is the error channel for about 96 call sites (download, attach, export and model failures). It never posts an accessibility announcement. The banner disappears after 5 s, the title is limited to 2 lines and the detail to 4. The only announcement in the app is the voice phase. Reply completion and reply failure in chat are also not announced. | `Services/ToastCenter.swift:52-72, 146-152`; `VoiceConversationView.swift:45` | Post `AccessibilityNotification.Announcement` in `show(_:)`. Keep error toasts until dismissed when VoiceOver is running. |

## P2 — should fix

| # | Finding | Evidence |
| --- | --- | --- |
| 7 | **Opening Settings from the sidebar discards your place.** `openSettings()` sets `selectedTab = .home`, so dismissing Settings leaves you on Chats, not in the chat you were reading. The chat's own overflow menu instead opens a separate `SettingsView` sheet in place. That gives two presentations with different return behavior. | `ODConversationDrawer.swift:146-150`; `CodingAssistantView.swift:626` |
| 8 | **Model management is split across 7+ entry points and two parallel UIs.** They are the Models workspace, Models → Core AI packs, Models → Browse catalog (`HFSearchView`), Device → Model library and imports (the 4,509-line legacy `ModelsManagerView`), Device → Manage storage, Device → Downloads and model operations (`ModelDownloadCenterView`), Settings → Models & AI → Downloads, and the chat model picker. Users cannot predict where install, delete, storage or import live. | `HomeView.swift:37-49`; `ContentView.swift:282-314`; `SettingsView.swift:319+` |
| 9 | **Conversation management is split, and deletion is unsafe.** The primary Chats list offers only Pin (long press); its hint promises "More actions are available". Delete, export and copy live in a second list ("Manage conversations"). There, a **full swipe deletes with no confirmation and no undo**, and so does the context-menu delete. No surface can rename a conversation. | `ODConversationsHome.swift:186-201`; `CodingAssistantView.swift:4408-4448` |
| 10 | **The chat overflow menu is a kitchen sink.** It has about 17 items: navigation that duplicates the sidebar (Past conversations, Device, Voice, Image generation, Settings), conversation actions, persona, web settings, an Advanced submenu, and "Diagnose app errors". Diagnose appends a diagnostics exchange **into the user's current conversation**. Stale comments reference toolbar buttons that no longer exist. | `CodingAssistantView.swift:438-572, 2576-2583` |
| 11 | **Three accent systems.** Host (Kodu) views use monochrome ink as the accent. Package views use `ODAccent` (`#007AFF` / `#A1C3FF`). Primary pills hardcode `.tint(.blue)` in 5 places. Untinted controls fall back to system blue. The `AccentColor` asset (`#1D4ED8`, no dark variant) is dead: `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` is not set. On a single Models row, "Loaded ✓" is black and "Selected ✓" is blue. | `ODComponents.swift:116`; `ODConversationDrawer.swift:129`; `KoduTheme.swift:66`; `project.yml` |
| 12 | **Small-text contrast.** `ODAccent` used as text in light mode is 4.02:1: "Selected", "Manage" and the Discover kind caption. The orange "Needs attention" footnote is **2.20:1**. | `ODModelsView.swift:221-223, 251, 343, 397` |
| 13 | **The API server page uses a different visual language.** It has monospaced caps eyebrows, heavy bordered 24 pt cards, a "LIVE PARSER" readout and an unlabeled bug glyph, and brands itself "OnDevice Max" where the rest of the app says "OnDevice". The Start/Stop control, the page's main job, is the fourth card. | `api-running-dark.png`; `LocalAPIServerView.swift` |
| 14 | **No hardware-keyboard support.** There are zero `keyboardShortcut` uses. Return inserts a newline (by design), so a keyboard user has no ⌘↩ to send, ⌘N for a new chat or Esc to stop. This matters for the Mac Catalyst destination in `project.yml`. | `grep keyboardShortcut` = 0 |
| 15 | **Navigation is modal almost everywhere.** There are 104 `.sheet`/`.fullScreenCover` calls against 7 push destinations; the prior audit counted 93. Device rows show push chevrons (`chevron.right`) but open sheets, and sheets stack three deep: Device → Model library → import. | `HomeView.swift:40-69` |
| 16 | **The code-block Copy target is about 12 × 40 pt**, well below 44 pt. It has no minimum frame. | `CodingAssistantView.swift:5219-5238` |

## P3 — polish

| # | Finding | Evidence |
| --- | --- | --- |
| 17 | The leading "C" of "Change with your system settings." is clipped in the Appearance toggle. Reproduced in two captures on iOS 27; possibly an SDK beta issue. | `ODAppearanceChoices.swift:23-30`; `shots/settings-dark-crop2.png` |
| 18 | The onboarding "Get started" button renders as a small capsule, although the code asks for full width: the frame is applied outside `.glassProminent`. The copy mentions "paired Mac tools", which are hidden in this build. The legal gate points to "Settings → Legal", but the page is now "Privacy & Legal". | `OnboardingOnePager.swift:23, 36-41`; `LegalAcceptanceView.swift:61` |
| 19 | Inconsistent terminology: "New chat" ×6 vs "New conversation" ×2; sidebar "Voice" vs title "Voices"; "Ornith 1.5" (Models) vs "Ornith 1.5 9B" (Device, API); "OnDevice" vs "OnDevice Max". Settings subtitles are lower-case jargon ("assistant, api keys, fastvlm pipeline"). "Web Tool (off)" and "User Guide" are title case while the shell uses sentence case. | `SettingsView.swift:154-173`; `CodingAssistantView.swift:519` |
| 20 | Library copy is inaccurate. "2 in catalog" is actually the installed count. The Discover empty state says "Check your model catalog" directly above "Browse the model catalog". | `ODModelsView.swift:148-149, 310` |
| 21 | The "Clear conversation?" dialog has no message and uses the default title visibility, so the destructive "Clear" button appears without saying what is lost. | `CodingAssistantView.swift:574` |
| 22 | In Lens, the Photos and Capture labels are not baseline-aligned, and the bar is unbalanced because camera switching is omitted. | `shots/lens-light.png` |
| 23 | Reduce Motion is not respected by the HF search skeleton shimmer, the toast spring/slide, or the chat's `isGenerating` animation. | `GlassEffects.swift:266-276`; `ToastCenter.swift:113-124`; `CodingAssistantView.swift:405` |
| 24 | A failed Lens photo import (for example, an iCloud-only asset or a decode failure) does nothing and shows no message. | `ContentView.swift:341-342` |
| 25 | The 20 pt leading edge-swipe strip sits above every workspace with a `contentShape`, so taps in the first 20 pt never reach content beneath it. | `ODWorkbench.swift:73-79` |
| 26 | Code drift: dead `MARK` blocks for deleted Lens views, a dead ternary in the picker, and the unused `AccentColor` asset. | `ContentView.swift:654-763`; `AssistantModelPickerView.swift:190` |

## Verified healthy

- Icon-only buttons are labelled; brace-matched sweeps found no unlabelled cases.
  Rows combine children and expose selection, header and value traits.
- Dynamic Type: `sans()`/`serif()` map to text styles, only about 27 text sites
  use fixed sizes, and the composer, drawer, rows and Appearance switch to
  stacked layouts at accessibility sizes (`shots/composer-ax5.png`).
- Destructive model actions (delete, cancel download), API key rotation and
  privacy reset are confirmed with dialogs that name what is lost.
- Dark mode on the package screens, Device, API server and Image studio renders
  without contrast problems apart from #2 and #12. Default system tint is the
  adaptive system blue.
- Permission prompts explain their purpose clearly and name the feature.

## Not covered

Production-only surfaces (the full Settings tree, transcript rendering with real
Markdown, the model pickers, Knowledge base, Benchmark/Compare, legal documents)
were source-reviewed only. The Mac Catalyst layout, real VoiceOver navigation,
and anything involving inference, camera, microphone or downloads need the
paired iPhone.
