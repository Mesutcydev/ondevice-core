# Home, Models and Appearance redesign — build 40

This pass responds to the four dark-mode device screenshots supplied after
build 39. It supersedes that build's Home, Models and Appearance layouts.
The supplied native controls and neutral palette remain the design direction.

## Changes

- **Home:** replace the repeated centered logo and sparse rows with a
  left-aligned serif opening, explicit writing and Image studio actions, and
  ruled recent-conversation rows. Start writing focuses the existing composer without replacing an unfinished draft;
  Image studio uses the existing route. Recent rows open their actual stored
  conversation and All opens the existing drawer. Previews read only visible
  user/assistant messages, never hidden grounding or system prompts. Existing
  loading, retry, model switching and capacity-override paths remain present.
- **Appearance:** show Light, Dark and OLED as three visible preview choices.
  Following the device is a separate toggle. Replace the nested legacy card
  and duplicate rules with native App icon and Preferences sections. Preserve
  icon switching, language selection, haptics, FPS and tip reset bindings.
  Failed app-icon changes now restore the actual selected-icon indicator.
- **OLED:** restore the persisted `oled` value as its own preference. It uses
  dark controls over an RGB 0/0/0 page canvas, rather than silently mapping to
  ordinary dark mode. Propagate the preference through the package, sheets,
  composer and host theme without recreating the workbench or its drafts.
- **Models:** replace the oversized grouped cards with a flat library. Use
  typographic model titles, secondary specifications, explicit residency and
  default status, a compact capability filter, and plain storage/pack links.
  Preserve native primary tabs, search, Installed/Discover, model detail
  actions, deferred action dispatch and active-voice Return/End controls.

No new dependencies, model downloads, generated artwork or runtime-loading
paths are introduced by this redesign. The release script checks catalog URLs;
it does not bundle model weights.

## Verification scope

The simulator review host compiles the production package and the actual host
Home and Appearance section layout. Its icon assets are the app's existing
asset catalog. Runtime services and icon-change side effects are isolated
fixtures; the production archive compiles the real services and settings.

The full CoreAI app remains device-only. Simulator UI checks cannot prove live
camera frames, microphone input, inference or sideload installer behavior on
an iPhone. The build-39 Lens observation fix is retained; its regression tests
are included in this pass.

Final test results, release receipt and delivery confirmation are recorded below.

## Test results

- All 20 native UI flows passed, plus 11 host contract checks (including the
  two camera tab/mode observation regressions).
- The final Home action test also confirms an unfinished draft survives using Start writing again.
- All 5 package contracts passed, including restoring a persisted OLED choice.
- After the final accessibility preview refinement, both appearance tests
  passed again with a successful Xcode test exit.
- Screenshots reviewed in Light, Dark and OLED, plus 320 pt width and large
  accessibility text. Appearance previews switch to horizontal preview/label
  rows at accessibility sizes. Active voice controls remain reachable.
- Sampled the captured Appearance page canvas at the same pixel: Light
  `(248, 248, 247)`, Dark `(21, 21, 23)`, OLED `(0, 0, 0)`.
- The Home screenshot comparison against build 39 confirms the intended
  content changes while the native composer and tab shell remain in place.
- Repository hygiene validation and `git diff --check` passed. App/extension
  entitlement files and `Podfile.lock` match the pre-build SHA-256 inputs.

Xcode 27 stalled while finalizing two earlier result bundles after logging all
individual results. Those completed commands were stopped; no test failures
are concealed by that cleanup. The final appearance run and package run use
`-collect-test-diagnostics never` and both exit successfully. The QA script now
uses the same flag while continuing to save its screenshots and test results.

Evidence: `build/native-ui-evidence/build-40/`,
`build/native-ui-build40-full.log`,
`build/native-ui-build40-final-appearance.log`, and
`build/native-ui-build40-package-contracts.log` (local, uncommitted artifacts).

## Final release

The final release script completed all eight stages after the last source
changes. All 323 recorded Swift/configuration input hashes still match.

- Artifact: `OnDeviceMax-sideload-entitled-1.0.0-40.ipa`
- Version/build: 1.0.0 / 40; 45,993,824 bytes
- SHA-256: `9465e522a25ef4a7bd8f672de53e99c945c08bd3a073a9ef33216b33cc33ac6e`
- The independent verifier confirms a Payload-only ZIP, arm64 app, matching
  app and extension build numbers, both native runtime frameworks, privacy
  manifest and permission descriptions, valid nested code signatures, and
  exact original app/extension entitlement dictionaries.
- Profile-less ad-hoc signing: the sideload installer must re-sign both the
  app and share extension.

Receipt: `build/releases/OnDeviceMax-sideload-entitled-1.0.0-40.verification.json`.
The verified IPA was copied into the existing shared OnDevice Builds iCloud
folder; its copied SHA-256 matches. Earlier builds remain available.
Finder then confirmed three build files in the shared folder. Build 40's
Uploading indicator cleared and it is marked “Added by Me”; the folder banner
continues to say “Folder shared on iCloud by Me.”
