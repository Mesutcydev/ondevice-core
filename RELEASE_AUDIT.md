# OnDevice Core AI Studio — Release Audit 1.0.0

## Build 14 Hierarchy and typography — 2026-09-18

A hierarchy pass on top of Build 10's monochrome language. Nothing was
re-designed; the same identity is now applied with three deliberate
typographic roles instead of one.

### Serif restored as the editorial role

Build 10 collapsed the app to sans + mono and lost the serif entirely. It is
back as the rarest face in the product, reserved for **proper names only**:

- SYS runtime panel — the resident model name (20pt)
- RUN empty state — the headline, which is the model's own name (27pt)
- VOX hero — the active voice's name (30pt, the largest type on the page)
- VOX rows — each voice name (17pt)
- VOX details sheet — the entry name (24pt)
- WGTS active card — the resident model name (20pt)

Every button, label, eyebrow, metric and caption stays sans or mono. Scarcity
is the mechanism: six serif lines in the whole app is what makes them read as
important, and a serif `Start` button would undo it.

### Contrast: the light-mode placeholder

Light `ink4` was `#A8AEB5` — **2.05:1 on the page**, below the 3:1 graphic
floor and the reason placeholder and inactive text read as disabled controls
rather than empty ones. Now `#7E858C`: 3.42:1 on bg, 3.19:1 on `surface`,
3.02:1 on `surface2`, still clearly lighter than `ink3` (4.5:1) so tertiary
metadata and disabled state remain distinguishable. Measured, not eyeballed.

The composer and both search fields now pass an explicit `prompt:` colour
rather than relying on the system default (~24% ink), which was the actual
source of the "washed out in light mode" composer.

### Geometry

Control radii moved to a short, role-based ladder — 8 for small tiles/chips,
10 for anything pressed, 16 for sheets. Structure stays square (`panel` /
`spine` = 0), unchanged from Build 10.

### Button system completed

Build 10 shipped Primary and Outline. Added Secondary (tonal wash),
Danger (muted coral `bad`), and a compact inline Primary/Secondary pair at
36pt for rows. All share `action` radius, `StudioPressStyle`, and the ink
fill — one family at four sizes.

**All 16 stock `.borderedProminent` / `.bordered` buttons are gone.** They sat
in the Core AI download controls, both model pickers, the voice catalog rows
and the camera-permission panel, each arriving with Apple's own tint, radius
and press animation. Zero remain in app code.

### Voice conversation (VOX) rebuilt

The screen previously opened with five bordered chips — readiness, engine,
fallback, route, test audio — above the orb, which is why it read as an
engineering debug surface. Now:

- **Header**: `● Conversation · <model>` (unchanged) with the settings glyph.
- **One metadata line**: `Alloy · Kokoro Neural · Speaker`, mono, tertiary.
  The route picker and the audio test are inline utilities on that line; the
  fallback/loading condition is a leading warning glyph. Every capability is
  preserved, no capability owns a box.
- **Orb is the centre**, with the vertical composition made explicit rather
  than left as unused space. The Metal implementation is untouched.
- **Phase block**: `LISTENING` in tracked mono over a sans explanation.
- **Console**: one three-bay dock — End (muted coral) / Voice / Mic — on
  mathematically equal columns, 60×46pt plates, hairline dividers between
  bays, mono labels beneath. The mic bay was previously a 45%-opacity
  disabled button pretending to be a control; it is now a readout that lights
  while listening. Labels use existing translated keys.

~110 lines of orphaned chip code deleted with it.

### SYS / WGTS

- **NEW SESSION** was a full-bleed 46pt mono slab — the "accidental giant
  rectangle" complaint. Now inset within its panel, 52pt, sans semibold, with
  a real disabled state.
- **On-device storage**: the amount was 11pt `ink2`, the same weight and near
  the same value as its own label. Now 15pt semibold ink; the usage rail
  thinned 6→4pt and lost its clip radius; **Clean up** went from an outlined
  chip competing with the legend to borderless underlined text at 44pt.
- **Downloaded only** lost its bordered card and is now a hairline-ruled row —
  one switch does not need its own container.
- **WGTS search** unified with the VOX field: `surfaceRaised` fill, `rule2`
  hairline, `chip` radius, explicit `ink4` prompt, 44pt clear target. One
  search grammar app-wide.
- **Core AI status strip**: the 4%-ink gray slab that read as placeholder UI
  is now a left-ruled informational line. The installed row lost its
  green-tinted card for hairline rules — colour on this screen is a condition.
- **Active model card**: the model name dominates, the repo line demoted from
  `ink3.opacity(0.82)` to plain `ink3`, and Unload/Swap reordered so neither
  management action competes with the title.
- **Session timestamps** on SYS moved to `ink4`, restoring the three-level
  metadata hierarchy (title / turns·tok-s / time) that had collapsed to two.

### Deliberately untouched

Inference, runtime scheduling, MLX/GGUF/Core AI behaviour, camera processing,
speech engines, networking policy, repository behaviour, model installation,
session persistence, the orb's Metal renderer, and every accessibility label
and identifier. The Lens mode bar and category rail already varied weight,
brightness and indicator on selection, so §7/§14 of the brief were already
satisfied and were verified rather than rewritten.

### Not verified

**No visual QA has been performed on this build.** Image analysis is
unavailable on the current inference provider (every attempt timed out), so
the light/dark × device × state matrix and the pixel-alignment pass are
outstanding. The changes are compile-verified and contrast-measured, but no
one has looked at them on a panel. Same three hardware blockers as Builds
8–10: CoreAI absent from the Simulator SDK, Catalyst blocked by this host's
iOS Support 26.6 against a 27.0 target, no device connected.

`swift test --package-path Packages/VoiceAgentOrb` fails on a missing Metal
toolchain cryptex (`/var/run/com.apple.security.cryptexd/.../metal`). This is
environmental and unrelated — `Packages/` is unmodified.

### Build 14 IPA

`build/releases/OnDeviceMax-sideload-entitled-1.0.0-14.ipa`

- Size: 45,445,662 bytes
- SHA-256: `3f485bb5c1ab44b899cab3c9c1e94b6571fc492fb2c289072945e25c571e5c2b`
- `Payload/`-only root; app 1.0.0 (14); all 8 verification stages passed
- Entitlements unchanged from Builds 8–13, re-read from the signed binary
- Installer-side re-sign required (ad-hoc)

The serif resolver went through three source revisions before this artifact:
the first baked a single `NewYork-Semibold` face name and would have
synthesized every weight from one cut; the shipped version resolves per
weight through `fontDescriptor.withDesign(.serif)` so each requested weight
maps to the matching New York cut, with a `design: .serif` system fallback if
the serif design is unavailable. An earlier build-14 IPA (45,439,052 bytes,
SHA `3d18a06…`) was packaged against the fragile first revision and has been
overwritten — do not trust that hash.

## Build 10 Monochrome — 2026-09-18

Four changes of direction, all user-reported, plus a new app mark.

### Signal colour removed

The lime accent is gone; the accent family resolves to pure white on dark and
pure ink on light. `good` follows it, so **the only hues left in the product
are `warn` and `bad`** — anything coloured on screen is now a condition, never
decoration or branding.

The lime worked structurally (it was unmistakably not an AI-app accent) but
read loud rather than expensive, and an instrument whose lamp is lit at all
times is not telling you anything.

Known trade-off, accepted deliberately: white-on-white is 1.21:1, so a "live"
value is no longer distinguishable from body text *by colour*. Liveness is now
carried entirely by the breathing LED, the generating scanline and position.
That is the cost of monochrome and it was chosen with that understood.

### Geometry: structure square, controls rounded

Build 8 set every radius to 0–2, which made the app read as an Android layout —
hard 90° corners on every button, chip and image tile. Corrected to a split:

- **Structure stays square** (`panel`, `spine` = 0). A full-bleed band has no
  visible corner to round; rules and screen edges do the work.
- **Controls are rounded** (`small`/`tile`/`chip` = 6, `glyph`/`action`/`send`
  = 8, `sheet` = 12). These are visibly rectangular objects and zero radius
  reads as unfinished on iOS.

This is not a retreat to cards. A card was a container with radius *and*
elevation *and* a fill, floating on a page. These are controls with a radius
and nothing else, sitting inside square full-bleed bands.

### Chat: bubbles replaced with a transcript

The user turn was a right-aligned, 288pt-max, tinted, rounded block with a
spine — the chat-bubble pattern, and the most recognisable piece of generic
assistant UI there is. Build 8's own brief said "chat is a transcript log, not
bubbles" and then shipped bubbles.

Both turns are now full-measure log entries headed by a speaker rule
(`YOU ──────`, `QWEN2.5-CODER-1.5B ──────`). No fill, no border, no alignment
trick, no max width. The assistant's label reads the message's recorded
`generationModelID`, so an old thread names the model that actually answered
rather than whichever is loaded now.

### SYS rebuilt around graphics

Reported as "low quality, looks like only text on a page" — accurate. The tab
was a stack of labelled text rows: structurally correct, visually inert. An
instrument panel where nothing has a shape is a list.

Added two primitives and wired them to live data:

- `InstrumentTrace` — 48 seconds of throughput drawn as a stepped line over two
  gridlines, scaled to the session peak so it does not rescale under itself.
  Stepped rather than splined because the samples are discrete; a smooth curve
  would invent values between them. `InstrumentTelemetry` now keeps the
  history.
- `InstrumentGauge` — labelled proportional bar. Memory (footprint against
  physical RAM, alarming past 85%) and weights-on-disk were previously byte
  counts in a text row: the two facts on the screen that are inherently
  proportional, printed as absolutes.

### App mark

`scripts/make_app_icon.swift` rewritten. The old mark was a "MAX" wordmark in
SF Pro Black over a top-down gradient sheen — it broke three rules of the
language at once and said nothing about the product.

The new mark is the app's own throughput trace: a stepped white line on
#0A0B0D, the same value as `LaunchBackground` and the dark page, so icon,
launch screen and first frame are one continuous surface. Two intermediate
versions were rejected during rendering — the first read as a staircase
(monotonic samples, 0.34 plot height, 5.4% stroke that merged adjacent steps),
the second carried `InstrumentTrace`'s two gridlines, which at icon scale have
no axis to belong to and read as stray hairlines escaping the glyph.

### Build 10 IPA

`build/releases/OnDeviceMax-sideload-entitled-1.0.0-13.ipa`

- Size: 45,408,710 bytes
- SHA-256: `7b3f82754aead334fb34c27cb48feca474ecd04bd91cf7705742059118730f23`
- `Payload/`-only root; app 1.0.0 (13); all 8 verification stages passed
- Entitlements unchanged from Build 8 and re-read from the signed binary

Contrast re-measured for the monochrome palette: every pair passes, worst case
7.23:1 (`bad` on page). Still unrun on hardware — same three blockers.

## Build 9 Instrument polish pass — 2026-09-18

Craft-level pass over Home, the chat thread and the composer after Build 8
established the language. Build 8 answered "is it consistent"; this one answers
"is it good". Ten defects, six of them in Build 8's own work.

### Reported by the user

- **Telemetry band too heavy.** The strip was a ~46pt slab: label stacked over
  a 13pt value, 7pt vertical padding, boxed by three full-height dividers —
  four gauges outweighing the content beneath them. Rebuilt inline at 9/11 with
  the dividers dropped, bringing the band to ~27pt. Telemetry is ambient; it
  has to be legible without competing.
- **Mixed button geometry.** 28 circular shapes survived Build 8's sweep, which
  had only caught small status dots: glyph backings, radio marks, avatars,
  pulse rings. All square now. One exception, documented at the call site — the
  camera shutter, which is round on every camera ever made.
- **Sessions panel headers indistinguishable.** Panel titles sat on the page at
  the same value as row detail text, so stacked panels read as one continuous
  list with no boundary between SESSIONS and SUBSYSTEMS. Headers are now a
  filled `surface3` band, `ink2` at 9pt medium, tracking 1.2, closed by a rule.
- **No sign of life.** A lit `InstrumentLED` now breathes — 1.5s at rest, 0.55s
  while generating — and a lime scanline sweeps the telemetry bar's bottom rule
  during generation. The sweep is functional rather than decorative: token rate
  arrives in bursts, so a stalled runtime and a working one are indistinguishable
  on the numbers alone for a second or two. Both stop under Reduce Motion, and
  an unlit LED never animates.

### Found by audit

- **`VoiceConversationView` was hard-locked to light.** The view ended with
  `.preferredColorScheme(.light)`, so opening Voice from a dark app flipped one
  full screen to white and flipped back on exit. Invisible to every static
  colour scan in Build 8 because it is a modifier, not a value. This was the
  loudest remaining inconsistency in the product.
- **The composer was still a card.** Squaring its corners was not sufficient —
  a square panel inset 12pt with a border on all four sides still reads as an
  object resting on the page. Now full-bleed with a single top rule. Focus
  turns that rule lime instead of ringing the panel, which had been putting
  more accent on screen than the send button the colour is reserved for.
- **Two press languages.** `StudioPressStyle` scaled to 0.93 across 11 controls
  while `InstrumentPressStyle` dimmed across 4. Collapsed to one opacity-only
  style; the Instrument name is now a `typealias`, so they cannot drift apart.
- **Three left edges on Home.** Masthead at 16, panels and rows at 14,
  telemetry cells at 9. One grid line at 14.
- **Rationalised dead code.** Build 8 kept two `.shadow` calls "so the file has
  no dead elevation logic to re-delete later", including a
  `radius: isFocused ? 22 : 16` ternary feeding a value nothing drew. Deleted.
- **The signature element appeared once.** `InstrumentBar` shipped on Home
  only — the screen where none of its four numbers move. Added to the chat
  screen, and the composer's generating row dropped its now-duplicated metrics
  down to LED + state + thermal + STOP.

Copy: `thinks First/Off` → `reason ON/OFF`. Colour rule enforced on the two
remaining primary actions — STOP is outlined because lime means *run*
everywhere else, and a filled lime control that halts work would invert the
design's only colour rule; the blocked-state CHOOSE went to lime, being the
sole pressable control when no weights are resident.

Hardcoded white/black that remains is camera-overlay chrome in `ContentView`
(white on a black scrim over the live feed), which is correct independent of
appearance and was verified as such rather than swept.

### Build 9 IPA

`build/releases/OnDeviceMax-sideload-entitled-1.0.0-12.ipa`

- Size: 45,525,805 bytes
- SHA-256: `1ee4b2633e9a2ef4d9cb98cd01dda50fe487139db424da0e4e02210f7af5808b`
- Root structure: only `Payload/`; app `Payload/OnDeviceMax.app`, 1.0.0 (12)
- Nested code signed: `llama.framework`, `whisper.framework`,
  `OnDeviceMaxShare.appex`
- Signature verified `--deep --strict`; ad-hoc, installer re-sign required
- All six app entitlements and the extension App Group read back from the
  final signed binary, unchanged from Build 8

Still not run on hardware — same three blockers as Build 8 (CoreAI absent from
the Simulator SDK, Catalyst blocked by this host's iOS Support 26.6 against a
27.0 target, no device connected). The animation work in particular is
unverified: breathing cadence and sweep timing are the kind of thing that only
reads correctly in motion on a real panel.

## Build 8 Instrument redesign — 2026-09-18

Full visual-language replacement. The previous design was a rounded-card,
soft-shadow, near-white assistant shell; the app is a local inference runtime,
and the redesign makes it read as one. The change is geometric and structural,
not a palette swap — an earlier attempt that only retuned colour tokens is what
prompted this one.

### UI audit

Measured across `IOSLocalLLM/` after the sweep, all counts verified by grep:

| Check | Before | After |
|---|---|---|
| Hardcoded `cornerRadius: <n>` (bypassing tokens) | 343 | 0 |
| Blur materials (`.thinMaterial` etc.) | 4 sites | 0 |
| Black elevation shadows | 4 | 0 |
| Decorative gradients | 3 | 0 |
| Text below 9pt | 6 | 0 |
| Display type ≥26pt | 9 | 0 |
| Circular status dots | 14 | 0 |
| Hardcoded `Color.white` surfaces | 1 | 0 |

`StudioRadius` now resolves to two values — `0` for anything that tiles, `2`
for anything you press. That single change propagates through 479 call sites
and is what stops surfaces reading as floating cards. `shadowAmbient` and
`shadowKey` return `.clear`, so pre-existing `.shadow(...)` calls compile and
draw nothing rather than needing individual deletion.

Six gradients remain and are deliberate: two alpha masks (marquee text edge
fade, bottom scrim), and three live-state indicators (Lens scan beam, VLM
streaming sweep, activity shimmer — the last retinted from a white specular
sheen to a lime scan pass). None are decorative surface treatment.

### UX audit — defects found and fixed

Four real defects, none of which were visible without measuring:

1. **Contrast failure across most body text.** The new page dropped to
   `#0A0B0D` but the ink ramp was carried over, leaving `ink3` — which carries
   every mono micro-label in the app — at 3.99:1 on the page and 3.80:1 on
   `surface3`, below the 4.5:1 floor. OLED failed too (4.26:1). The ramp was
   re-solved against all four dark surfaces: `ink3` → `#848B93` (4.75:1 worst
   case), `ink2` → `#A8AEB6` (7.32:1), `ink4` → `#6B7178`, held to the 3:1
   graphic floor as placeholder/disabled/LED-off only. Level separation is
   1.56–1.96× so the four-step hierarchy survives.
2. **Type below any readable floor.** Panel and telemetry labels shipped at
   7pt, with six more 8pt sites app-wide. All raised to a 9pt minimum.
3. **Dark-first design defaulting to light.** `AppSettings.appearance`
   defaulted to `"light"`, so the `make()` dark default could never fire and
   every fresh install opened in the weaker light reading. Default is now
   `"dark"`; existing users keep their stored choice, since `@AppStorage` only
   falls back when the key is absent.
4. **Launch flash.** The launch asset was `#DADADC` light grey against a
   `#0A0B0D` first frame. `LaunchBackground.colorset` now matches the page
   exactly, and the splash — a white radial bloom over a light page with a
   shadowed, rounded icon — was replaced by a boot readout on the same value.

Light and OLED appearances were re-measured and pass at every level.

### Build 8 IPA

`build/releases/OnDeviceMax-sideload-entitled-1.0.0-11.ipa`

- Size: 45,524,102 bytes
- SHA-256: `76d3685c7cd03a7644ad80a8e5986d1dd8d5770336a9cd2d56e522957dd7574e`
- Root structure: only `Payload/`
- App: `Payload/OnDeviceMax.app`, bundle `com.mesutcydev.ondevicemax`, 1.0.0 (11)
- Nested code signed: `llama.framework`, `whisper.framework`,
  `OnDeviceMaxShare.appex`
- App signature: ad-hoc, verified `--deep --strict`; installer re-sign required
- Privacy manifest: present in app and extension
- `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`: true
- CoreAI linkage asserted via `otool -L` during packaging

Entitlements read back from the final signed binary:

- `com.apple.developer.kernel.increased-memory-limit`
- `com.apple.developer.kernel.extended-virtual-addressing`
- `com.apple.developer.private-cloud-compute`
- `com.apple.security.application-groups` → `group.com.mesutcydev.ondevicemax.shared`
- `com.apple.developer.icloud-container-identifiers` → `iCloud.com.mesutcydev.ondevicemax`
- `com.apple.developer.icloud-services` → `CloudKit`

Share extension carries the matching App Group and nothing else.

Verified unchanged: all eight `HomeView` navigation callbacks still wired
through `ContentView`; `InstrumentRow` and glyph targets hold the 44pt
minimum; every font routes through `Font.custom(_:size:relativeTo:)` so
Dynamic Type still applies; 43 `reduceMotion` guards intact. Telemetry reads
live services (`tokenRate`, `estimatedInputTokens`, `MemoryAdvisor`,
`ProcessInfo.thermalState`) and renders `—` rather than a fabricated zero.

### Not verified

No device or simulator run. CoreAI is absent from the Simulator SDK (confirmed
again this build: present in `iPhoneOS27.0.sdk`, absent in
`iPhoneSimulator27.0.sdk`), Mac Catalyst is blocked by this host's iOS Support
Version 26.6 against the app's 27.0 deployment target, and no physical device
was connected. Correctness is established by `BUILD SUCCEEDED` on
`generic/platform=iOS` and by static measurement only. The visual result is
unconfirmed on hardware — install and check the four screens above.

## Build 7 LFM answer-quality hotfix — 2026-08-22

- Fixed LFM2.5 2.6B returning raw
  `<|tool_call_start|>[knowledge_base(...)]<|tool_call_end|>` protocol text
  instead of answering ordinary questions. The Assistant now honors the
  curated Core AI pack's `supportsTools` capability before advertising or
  executing tools.
- Unsupported Core AI tool dialects receive a short direct-answer guardrail
  instead of the full tool catalog. This removes a large, irrelevant prompt
  from LFM's constrained on-device input budget and prevents unnecessary
  knowledge-base calls.
- Persisted conversations are sanitized when reopened with an unsupported
  Core AI tool dialect, so a tool catalog from a previously selected model
  cannot leak across model switches.
- MLX and GGUF retain their existing tolerant text-tool behavior. Tool-capable
  Core AI packs such as Nanbeige remain tool-enabled.
- Fixed Core AI tool follow-up planning so a trailing tool result is actually
  supplied to the synthesis pass.
- Xcode 27 Release archive and device `build-for-testing` succeeded.
  VoiceAgentOrb tests: 25 passed. Simulator execution remains unavailable
  because Apple's CoreAI module is device-only in this toolchain.

Build 7 IPA: `build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-7.ipa`

- Size: 51,598,481 bytes
- SHA-256: `5c1df91257b44972687040ebfae0dba2204d46a3488ec11ce2ecf482ea14480f`
- Final Payload/signatures, nested frameworks, share extension, privacy
  manifest, file-sharing flags, PCC, increased-memory, extended-addressing,
  iCloud and matching App Group entitlements all passed the release script.

## Build 6 performance and thermal hotfix — 2026-08-22

- Core AI EOS, user Stop, task cancellation, and abandoned stream consumers
  now cancel and drain the pipelined GPU producer instead of allowing hidden
  decoding to continue to the response-token limit.
- Cancellation waits for already-committed command buffers before returning
  the engine slot, preventing buffer reuse while GPU work is retiring.
- Core AI now uses the same thermal/memory admission cap as MLX/GGUF and stops
  an in-flight request if the device reaches critical thermal state.
- Fixed-S=1 Core AI pipelines are constrained to the verified-correct 1024 KV
  state range on iOS; the app advertises a 512-token Core AI output ceiling and
  compacts input to leave template/EOS headroom.
- Hybrid reasoning models receive `enable_thinking` through their tokenizer
  chat template. LFM2.5 2.6B remains correctly classified as reasoning-only.
- Core AI diagnostics now separate time-to-first-token from decode rate.
- Existing MLX behavior is unchanged. GGUF received only the missing
  critical-thermal in-flight cancellation guard.
- Xcode 27 device build and device test build succeeded. VoiceAgentOrb tests:
  25 passed. Simulator execution is unavailable because Apple's CoreAI module
  is device-SDK-only in this toolchain.

Build 6 IPA: `build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-6.ipa`

- Size: 51,597,548 bytes
- SHA-256: `209d488fe04256e6a7d272cb6bfbea7ae96f4d796fdaf7bb3032d87e1043c88c`
- Final Payload/signatures, nested frameworks, share extension, privacy
  manifest, file-sharing flags, PCC, increased-memory, extended-addressing,
  iCloud and matching App Group entitlements all passed the release script.

Audited and packaged with Xcode 27.0 / iPhoneOS 27.0 SDK.

## Product basis

This is a copy of the real CodeLens workbench (`CodeLens` HEAD `72a0c65`), not
the separate Core AI: LAS server product. It retains all five tabs and existing
runtimes:

- Home
- Assistant
- Lens
- Voice
- Models
- MLX / llama.cpp-GGUF / Whisper / Core ML
- Share extension, local API, Mac bridge and Apple Private Cloud

Apple Core AI is an additional local Assistant runtime selected alongside MLX
and GGUF. It does not replace those catalogs or features.

## Identity

- Project/workspace/scheme: `OnDeviceCoreAIStudio`
- Display name: `OnDevice Core`
- Bundle: `com.mesutcydev.ondevicecore`
- Share extension: `com.mesutcydev.ondevicecore.share`
- App Group: `group.com.mesutcydev.ondevicecore.shared`
- CloudKit: `iCloud.com.mesutcydev.ondevicecore`
- URL scheme: `ondevice-core`
- Minimum OS: iOS 27.0
- Version: 1.0.0 (7)

## Core AI runtime integration

- `ModelRuntime.coreAI` and `coreai:<catalog-id>` persisted selections.
- `CodingAssistantService` load / generate / stop / drain / unload / switch
  paths support Core AI without treating it as PCC.
- Lazy specialization on first Send.
- Same conversation history, context trimming, JSON mode, tool envelopes,
  token accounting and per-conversation model restoration as existing models.
- Unload-before-load policy drains Lens/MLX/GGUF before Core AI specialization.
- Core AI runs through the same memory/thermal/low-power admission gate.
- Background lifecycle cancels and unloads Core AI with the other heavy
  runtimes.
- Voice can continue using the selected Assistant runtime for reply generation;
  Lens remains on its existing MLX/GGUF vision pipelines.

## Model catalog and downloads

- 22 direct Hugging Face Core AI packs audited.
- Assistant UI offers the 16 official/chat packs; VLM/embedding/ASR packs are
  not falsely advertised as chat models.
- Exact repository subtrees — never the whole multi-platform repo.
- Measured download sizes and exact file links.
- Foreground sideload-safe downloads, pause/resume/retry/cancel.
- Wi-Fi-only policy, free-space preflight with partial-download credit and 1.5
  GB install headroom.
- Hugging Face LFS SHA-256 is checked incrementally for every LFS-backed file
  before installation; bad files are removed.
- One Core AI pack is installed at a time. Replacing it drains a live runtime,
  removes the previous multi-GB tree, and updates active/default identity
  safely. MLX/GGUF files are untouched.
- `Wipe all data` now includes Application Support/CoreAIModels and its setting.

Verification:

```text
verify_zoo_catalog.sh       All catalog invariants hold
verify_zoo_downloads.py     all 22 packs verified downloadable
build-for-testing           TEST BUILD SUCCEEDED
release archive             succeeded
FoundationModels preflight  no deprecated or missing imports
```

## UI/UX audit

- Existing CodeLens navigation and tab structure preserved.
- Core AI is embedded in Models → Assistant, not introduced as another product
  shell.
- Dedicated installed-pack card, download progress and exact-files/license UI.
- Installed Core AI pack appears in the normal Assistant picker with a CORE AI
  runtime badge.
- Missing-pack state links directly to Models.
- Replacing/removing packs resets selection safely and states explicitly that
  MLX/GGUF are unchanged.
- Ready status distinguishes `Ready via Apple Core AI` from PCC and other local
  runtimes.
- User-visible onboarding, splash, diagnostics, Shortcuts and review copy use
  `OnDevice Core`; the separate `iOS Local LLM Bridge` companion name and the
  upstream iOS Local LLM legal attribution remain intact.

### Download-start regression

The first sideload build made a Core AI download look inert after tapping
Download. Root cause had two layers:

1. `CoreAIHFDownloadManager.start()` scheduled a Task but left its published
   state at `.idle` until that Task later ran, so the same-frame button state
   did not acknowledge the tap.
2. The catalog card read a child manager from `CoreAIDownloadCenter`, but did
   not observe that manager. The center publishes manager insertion/removal,
   not every child's progress tick, so later enumerating/downloading/progress
   changes never redrew the controls.

Fixed by publishing `.enumerating` / `.downloading` synchronously in `start()`
and by rendering each manager through `CoreAIDownloadControlsView`, which owns
an `@ObservedObject` reference to that manager. Added immediate start/resume/
retry toasts, an indeterminate listing spinner, live bytes/total/speed, and
`CoreAIDownloadManagerTests.testStartPublishesVisibleStateSynchronously`.

The exact fixed tree again passed `build-for-testing` before IPA packaging.

A physical-device UI/inference run was not executed by the agent: the CoreAI
module is absent from the Simulator SDK, and the final IPA is intentionally
ad-hoc/re-signer-ready. Re-sign it with ForgeSign/AltStore or your provisioning
profile before installing on an iOS 27 device.

## IPA

`~/Desktop/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-1.ipa`

- Size: 51,485,934 bytes
- SHA-256: `86190c64eb2923e7d9cf4d7afbbd7da12c084a81069b2bc98ff7d22dfa6060cd`
- Root structure: only `Payload/`
- App: `Payload/OnDeviceCoreAIStudio.app`
- App signature: verified ad-hoc; installer re-sign required
- Privacy manifest: present
- CoreAI, llama and whisper frameworks: all linked/present
- Share extension: present and signed
- `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`: true

Embedded app entitlements verified from the final IPA:

- `com.apple.developer.kernel.increased-memory-limit`
- `com.apple.developer.kernel.extended-virtual-addressing`
- `com.apple.developer.private-cloud-compute`
- `com.apple.security.application-groups`
- `com.apple.developer.icloud-container-identifiers`
- `com.apple.developer.icloud-services`

The share extension carries the matching App Group entitlement.

## Isolation proof

- `/Users/m/Desktop/CodeLens`: clean at `72a0c65`.
- `/Users/m/Desktop/OnDeviceLAS`: no `OnDeviceCoreAIStudio`, bundle-id, or Core
  AI section artifacts from this work at `82fcdd59`.
- The earlier mistaken LAS-derived attempt is preserved separately at
  `/Users/m/Desktop/OnDeviceCoreAIStudio-LAS-WrongBackup` and is not used by
  this release.
