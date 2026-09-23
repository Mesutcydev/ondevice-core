# QA loop handoff — 2026-09-18

> Historical handoff. The current user-supplied native design supersedes the Instrument styling, tint, halo and typography guidance below. Use [NATIVE_UI_IMPLEMENTATION.md](NATIVE_UI_IMPLEMENTATION.md) and `Packages/OnDeviceUI/Documentation` for current presentation and validation. The leading keyboard-dismiss key remains required. The latest user reference explicitly supersedes the TabView rule; see the current sidebar section below.

## Current: 2026-09-19 sidebar navigation

The current UI pass follows `/Users/m/Downloads/OnDevice-UI-UX-Codex-Prompt.md`.
See `Docs/UI_UX_BRIEF_2026-09-20.md` for the route map and validation record.
The retrieved phone log confirms a completed Ornith response on build 42;
the preceding build 41 stall's exact trigger is not proven. See the updated
[regression audit](RELEASE_BLOCKER_AUDIT_2026-09-20.md).

`OnDeviceWorkbench` is the active shell. Chats owns conversation browsing and
native search. The leading drawer owns workspace navigation, grouped as Create
and Manage; its former duplicate history list and the home's Workspaces list
have been removed. There is no bottom tab bar. Image studio and Device are now
retained primary workspaces. API server is also a retained primary workspace,
backed by `LocalAPIServerView`; Mac bridge navigation is hidden. Settings, model
selection and editing use sheets.
Legacy secondary-route requests redirect to the primary workspaces.

Retain visited workspaces to preserve drafts, attachments and reading position.
`WorkbenchSelectionObserver` forwards selections to the existing host camera,
audio and residency lifecycle. The host compatibility mapping must not overwrite
Image studio, Device or API server with Home. Do not replace this with a conditional shell
that discards the chat's request state.

Use `QA/NativeUI` for UI and interaction verification: the production app's Core
AI dependency is device-only. Dedicated QA simulators avoid interference with
other tasks: compact `D0EDAD87-10C5-4047-9963-2352D4370383`, large
`5575B8F8-981C-4CBF-BD4C-29D2B8BB557A`. A simulator fixture is not hardware
inference, camera or audio evidence. Keep builds separate from keyboard-heavy
UI checks; concurrent compilation has caused dropped simulator key events.

### Round 2: session ownership and refinement

See [ROUND2_IMPLEMENTATION.md](ROUND2_IMPLEMENTATION.md) for the implementation,
evidence and physical release gate. Capture demand now follows actual Lens
visibility through `WorkbenchSelectionObserver`, including the drawer, full
voice cover and result modal. `AnalysisService.start()` only prepares capture
configuration/metadata; it must not re-acquire a hidden camera. Host sheets also
release capture demand. Selected images retain their own pixels and prompt/model
operation snapshots.

Minimized voice belongs to the service and survives navigation. The shared
`ODWorkspaceBottomBar`/`ODVoiceSessionAccessory` is composed with each page's
footer under one inset. Keep the explicit retained-workspace visibility
environment: opacity/accessibilityHidden alone exposed duplicate voice controls.
Model/generation replacement confirms interruption, waits for voice selection
restoration, then proceeds. Do not restore navigation-triggered voice termination
or runtime unloads. Speech-engine selection confirms at the actual choice.

The following older sections document prior decisions, not the current shell.

## 2026-09-19 — shell rework (native bar inside the OnDeviceUI shell) ✅ verified
The tab shell is now `Packages/OnDeviceUI` (`OnDeviceWorkbench`), so the
navigator work belongs in that package, not in `ContentView`'s old `TabView`.

- **Custom bar deleted.** `ODWorkbench.tabBar` (a hand-built `HStack` mounted as
  `.safeAreaInset(edge: .bottom)`) is gone. The workbench now renders a real
  `TabView(selection:)` with `.tabItem` + `.tag`, `.tint(ODPalette.accent)` and
  `.tabBarMinimizeBehavior(.never)` (availability-gated). iOS supplies the
  Liquid Glass floating bar, its haptics, and its keyboard behaviour.
- **Why the bar and the composer fought:** two bottom `safeAreaInset`s stack —
  the bar was one, the chat composer was the other, so with the keyboard up the
  bar landed between the field and the keys. A real `TabView` fixes it
  structurally: the platform retracts the bar for the keyboard and every tab's
  content gets the bar's inset. **Verified in a simulator harness, not assumed**
  (see "Simulator verification" below): keyboard up → no bar on screen, composer
  directly above the keyboard.
- **Measured, not guessed:** a native `TabView` *does* inset a scroll view for
  the floating bar — content stops ~82pt above the screen edge on an iPhone 17
  (iOS 27 sim), i.e. above the bar. The 140pt `StudioSpacing.tabBarClearance`
  the old host tab pages carry is compensating for a structure this shell does
  not have, so the package uses `ODSpace.tabBarRunout = 24` as end-of-list
  breathing room only. Do not paste 140 into the package pages.
- **Keyboard hide key:** one per screen, in the keyboard's own accessory row,
  **leading edge, nothing trailing**. `KeyboardDismissKey` (host, in
  `Views/KeyboardToolbar.swift`) and `ODKeyboardDismissKey` (package) both take
  the focus binding so `@FocusState` clears with the keyboard. The composer's
  focus-conditional hide glyph was removed: it appeared/disappeared inside the
  control row and moved the send button sideways mid-typing, and it sat one row
  above the keyboard's own corner. Send now owns the trailing corner alone.
- **Soul pass** (user: "add some soul, now soulless"): `ODType` title roles are
  the editorial serif, `ODMotion` replaces literal durations, and
  `odScreenBackdrop()` puts one warm halo behind each screen's masthead.
  `ODMasthead` (eyebrow + LED + serif title + one plain sentence) replaces four
  hand-rolled headers; the System hero states the product's actual guarantee
  ("Runs on this iPhone. Nothing is sent anywhere."); the chat's empty state
  greets, explains, and offers three prompts that fill the field.

## Simulator verification (the real app cannot run in one)
CoreAI is device-only, so the app's own build is only ever a compile gate. Two
throwaway hosts are used to see pixels:
1. The handoff's own demo host (`OnDeviceUIHandoff/Example`) pointed at this
   package → screenshots of every package screen with the real native bar. Copy
   `Sources` into a scratch package root, keep `Example/` beside it, build with
   `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` (the project otherwise tries x86_64 and
   fails to resolve the package module). Launch-arg fixtures (`-odTab chat`,
   `-odMessages`) were added to the scratch copy only.
2. A minimal xcodegen harness for the chat/keyboard contract (TabView + bottom
   `safeAreaInset` composer + keyboard accessory row), auto-focusing its field
   from a launch argument. End-of-list clearance can only be seen at maximum
   scroll, so it scrolls itself with `ScrollViewReader`.
Gotchas: the first keyboard appearance in a fresh sim shows the "Slide to type"
tutorial over the keys; `simctl` screenshots include it.

## Task
Second-stage visual QA pass (render → critique → fix loop) on the Instrument
UI. User rejected the custom tab bar; **native `TabView` bar is back and must
stay** — do not rebuild a custom navigator.

## State (verified, compiles clean)
- Device build of the REAL app is GREEN: `xcodebuild -workspace
  OnDeviceMax.xcworkspace -scheme OnDeviceMax -configuration Debug
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` →
  BUILD SUCCEEDED (log /tmp/build_qa2.log).
- Extracted components in use by `VoiceConversationView` (real, not stubs):
  `IOSLocalLLM/Views/Voice/VoiceControlDeck.swift` —
  `VoiceSessionStatusLine` (VOICE/ENGINE/OUTPUT mono line, one speaker glyph,
  routeControl: AnyView? slot for AVRoutePickerView), `VoicePhaseReadout`,
  `VoiceControlDeck` (3 equal bays, readout kind for live mic, END=coral).
- Stage-1 polish already applied (do not redo): SYS dormant throughput
  (trace height 26→44, "AWAITING RUNTIME"), masthead AIRGAP LED status,
  InstrumentCell value 12/semibold, RUN serif conv title, quick-actions as
  instrument keys (30h/radius 8/fillActive/rule2), WGTS search 48pt,
  VOX header de-capsuled (flush ruled LED row) + flat 44 iconButtons,
  StudioSpacing.xxl 26→24, StudioRadius.action 10→12.

## Stage-2 (second agent, same day) — motion system + VOX migration
Device build GREEN after each step (`/tmp/build_vox2.log`). Nothing committed.
- **`StudioMotion`** added to StudioTokens: `tap`/`state`/`entrance`/
  `breathe`/`sweep`/`stagger`, plus `studioAnimation(_:value:)` which nils out
  under Reduce Motion. Use these instead of literal durations.
- **InstrumentKit**: `.contentTransition(.numericText())` on Cell/Gauge/Spec,
  animated `InstrumentMeter` fill, `InstrumentTrace` gained `live:` + a pulsing
  leading-edge marker, new `InstrumentEntrance` modifier (`instrumentEntrance(n)`,
  fires once per view lifetime — tab returns do not replay it).
- **VOX migrated off the card grammar onto Instrument.** `activeHero`
  (surfaceRaised + strokeBorder + 2 shadows) and `talkSection` are GONE, merged
  into `voicePanel` = InstrumentPanel mirroring SYS's runtime panel (LED +
  serif 20 name + EqualizerBars + InstrumentSpecs + InstrumentAction).
  `engineRow`→`enginePanel`, `filterRow`+search+list→`libraryPanel`,
  `sectionHeader`/`metric` deleted, rows moved to the 14pt panel grid.
  **`grep -rl shadowAmbient IOSLocalLLM/Views` is now StudioTokens only** —
  no view in the app floats. Keep it that way.
- Counts: `ModelDownloadCenter.hubCacheModelCount` (counted in the same walk
  as `totalStorageUsed`) fixes "878.5 mb · 0 installed". Do not reintroduce a
  count sourced from `models.filter(\.isReady)` next to a byte figure.
- `LocalizationService.effectiveLanguage` is now cached (was resolving the
  locale per `Text` per body pass).
- **`KSection` is now an `InstrumentPanel`** (KoduComponents.swift). One
  container vocabulary app-wide: 91 call sites across 23 files converged
  without touching any of them. The old 16pt page inset moved onto the
  content as 14pt, so panels are full-bleed and content shifted 2pt. Same for
  `KCollapsibleSection`. Do not reintroduce a bordered `surfaceRaised` box.
- `ModelsManagerView.sectionLabel` now matches the panel header band exactly
  (mono 9 / tracking 1.2 / ink2); was 11 / 0.9 / ink3.
- `grep -rn '\.shadow(' IOSLocalLLM/Views` returns four hits, ALL legitimate:
  three are state glows (selection, alarm, scanning) and one is a white close
  button over a live camera feed. No card elevation anywhere.
- `kGlass` was already flat (fill + 1px stroke, no blur) despite the name —
  no material anywhere in the app. Left as is.
- The 140/56 bottom paddings are **fixed** (`StudioSpacing.tabBarClearance`
  is 24; a native bar is already reserved in the scroll inset).
- Still left alone: `FastVLM:220`'s fatalError (verified unreachable — both call
  sites pass exactly one argument).

## SHIPPED: 1.0.0-36
`build/releases/OnDeviceMax-sideload-entitled-1.0.0-36.ipa` (sha256
`f35488208610a7fb241b87610a37e25af7dee3cac3ed5cd2ec1d8728eecd5bfe`,
44.7 MB / 46,851,605 bytes); `-latest.ipa` is byte-identical. Build bumped
35→36 in project.yml.

Contains: native glass tab bar, the contained composer, the keyboard hide key
(leading edge, no collision with send), the typography fix (`.system` instead of
`Font.custom(".SFUI-*")` — the app had been rendering Times New Roman), the
Models wiring, the 44pt/radius proportions pass, and the removal of the dead
Lens stack (`CameraRootView` + 8 helpers). Independently verified in the packed
binary: `hidesChooseModelAction` and `onShareFile` present, `CameraRootView` and
`LensPromptComposer` absent. 109 KB smaller than 1.0.0-35, which is the deleted
code.

Signing is **ad-hoc, `TeamIdentifier=not set`**: the installer must re-sign
(ForgeSign). Entitlements carried: increased-memory-limit, extended-virtual-
addressing, private-cloud-compute, app group `group.mesutcydev.ondevicemax.shared`,
iCloud `iCloud.com.mesutcydev.ondevicemax`.

Builds 14 and 15 remain known-bad references (14 = rejected custom tab bar).
**Note:** the IPA script needs `LANG`/`LC_ALL` set to `en_US.UTF-8` or CocoaPods
dies with `Encoding::CompatibilityError`.

## The render harness (/tmp/qa) — NOT YET COMPILING
`render.sh` compiles the app's REAL UI sources + fresh extraction from
CodingAssistantView.swift + stubs for Services, into a simulator binary, so
SYS/RUN/VOX/WGTS can be screenshotted (real app cannot run on simulator:
CoreAI device-only; host macOS lacks it too; see Docs/UI_UX_RELEASE_AUDIT).
- REAL files list is settled; includes VoicePresentationModels.swift,
  SpeechAlignment.swift (verified Foundation/Combine-only).
- Stubs (stubs.swift) seeded for Home/WGTS/VOX: qwen resident + idle smollm/
  phi4 + kokoro ready, 5 convos, no downloads in flight.
- harness.swift (App entry, tab shell mirroring ContentView + theme inject)
  **IS NOT WRITTEN YET** — this is the immediate next step.
- Run `bash /tmp/qa/render.sh`, iterate on `/tmp/qa/errors.txt` (grep error
  lines; add missing stub members as needed). Expect churn: ModelsManagerView
  and VoiceLibraryView reference many service members; stub surface is
  guessed, fix errors mechanically.
- If a real file pulls an import that can't compile (e.g. AVKit route picker,
  MetalKit orb), it's already in REAL and compiled fine per earlier probes —
  keep it real, don't stub views.

## After it renders
1. Boot `iPhone 17 iOS27` sim (D11A57A1-455E-4C48-B43A-6FE7C0EC8C21),
   `simctl install/launch`, capture all 4 tabs × light/dark
   (`simctl io screenshot`), inspect via vision_analyze at 100%.
2. Critique against the checklist in the user's brief (margins, baselines,
   separators, active states, cheap rectangles, buttons-in-buttons, empty
   states, bottom clearance vs NATIVE floating bar ~ 140/56 paddings).
3. Fix in REAL app files (not in /tmp/qa), rebuild device gate, re-render.
4. Ship note: `./scripts/build_sideload_ipa.sh build/releases`. Shipped
   1.0.0-36 (see the SHIPPED section above) after the producer-side audit; the
   harness is for *visual* regression only, not a release gate.
5. Commit nothing without asking; tree has ~80 uncommitted files by design.

## Gotchas
- `VoicePhaseReadout` is now fed by `uiPhase.statusLabel` + `fallbackDetail`
  (the "Say something" line stays inside `transcriptArea`).
- ContentView: do NOT re-add safeAreaInset tab bar; native bar overlays
  content, pages carry their own bottom clearance.
- InstrumentTelemetry sampler runs on any screen with InstrumentBar.
- stubs.swift `StoredConversation` custom init uses `self.init()` on the
  struct's own defaults (harness copy differs from real ConversationStore —
  that's fine, real file not included in harness).
- The tool `patch` sometimes drops new_string — prefer execute_code
  (hermes_tools patch) for edits.
