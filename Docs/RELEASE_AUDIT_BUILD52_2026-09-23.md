# Build 52 release audit — 2026-09-23

A full release audit of the build 52 candidate
(`OnDeviceMax-sideload-entitled-1.0.0-52.ipa`, archived 2026-09-22 20:12).
No source file was newer than that IPA when the audit started, so the working
tree was the build 52 source. It covered repository validators, the archive log,
the shipped IPA's `Info.plist`, entitlements and privacy manifest, the
network-exposed surface, logging and storage privacy, dead code and
documentation drift.

The same session also rebuilt the API server page after the OnDevice LAS
operator homepage (see [API server page](#api-server-page-las-redesign)).

## Verdict

Build 52 is **not release-ready**. The two blockers are process and hardware,
not code:

1. **The shipped source is not committed** (P0 below). No commit can reproduce
   builds 43–52.
2. **The full hardware release gate remains open.** Device reports from builds
   46–48 drove fixes in builds 47–49, but they do not verify the build 41
   first-token stall root cause or the ten Round 2 physical checks. Builds
   51–52 have no recorded device verification.

This audit fixed the pre-authentication remote crash and other code defects.
The subsequent cleanup addressed findings 8–12. These changes ship in the
next build, not in 52.

## Findings

| # | Pri | Finding | Status |
| --- | --- | --- | --- |
| 1 | P0 | Build 52 ships ~110 modified and ~30 untracked paths that were never committed, including the whole `Packages/OnDeviceUI` package, `ODBridge.swift`, `QA/NativeUI` and the deleted `PlumDuskSplashView.swift`. `project.yml` at `HEAD` does not reference `OnDeviceUI`, so no commit reproduces any IPA from 43 to 52. | **Open.** Commit on `ondevice-max` before the next archive. |
| 2 | P0 | Hardware gates carried forward from [build 42](RELEASE_BLOCKER_AUDIT_2026-09-20.md) and [Round 2](ROUND2_IMPLEMENTATION.md): stall root cause, camera, microphone, routes, thermal admission and real inference. [DESIGN_FIX](DESIGN_FIX_2026-09-20.md) records device reports on builds 46–48; these prompted fixes in 47–49 but do not close the full gate. Builds 51/52 have no device verification record. | **Open.** Needs the paired iPhone. |
| 3 | P1 | **Pre-auth remote crash.** `HTTPRequest(data:)` (shared by the Local API server and the Mac bridge) computed `headerByteCount + contentLength` from a client-controlled `Content-Length` before authentication. `Content-Length: 9223372036854775807` overflows and traps. Any LAN host could terminate the app with one request while the API server was on. | **Fixed** (`BridgeServer.swift`). Compared by subtraction. Oversized bodies still hit the 4 MB cap and close. Regression test added. A standalone `-O` build of the old parser exits with SIGTRAP (133); the fixed one returns `nil` and still parses normal bodies. |
| 4 | P1 | **Save Image crash.** Image studio shares the generated PNG file URL. The share sheet's *Save Image* runs in-process, and the app had no `NSPhotoLibraryAddUsageDescription`, so iOS terminates it on that tap. | **Fixed** in `project.yml` / `Info.plist`. |
| 5 | P2 | **Invisible status bar in dark mode.** `UIStatusBarStyleDarkContent` with `UIViewControllerBasedStatusBarAppearance = NO` forced black status-bar text app-wide. The default appearance is *System*, and `LaunchBackground` is `#151517` in dark mode. | **Fixed.** Both keys removed; SwiftUI's color scheme now drives the style. Confirm on device. |
| 6 | P2 | A previously paired Mac bridge auto-starts on foreground and advertises `_localllm._tcp`. Without `NSBonjourServices`, iOS 14+ refuses the advertisement, so Mac auto-discovery silently failed. | **Fixed** (`NSBonjourServices`). |
| 7 | P2 | API page: key rotation had no confirmation. A revealed key stayed visible in the app-switcher snapshot. The AWDL (`localAPIIncludePeerToPeer`, default **on**) exposure setting was unreachable in the UI. | **Fixed** in the redesign. |
| 8 | P2 | Local API and Mac pairing auth used a global lockout, allowing one LAN host to lock out others. | **Fixed** with a shared per-host throttle (`AuthFailureThrottle.swift`); the Local API test verifies independent hosts and lock expiry. |
| 9 | P2 | No cap on concurrent API connections. Each idle socket is held up to 15 s. | **Fixed** in `LocalAPIServer.swift`: 8 connections per host, 32 total. |
| 10 | P2 | `CHANGELOG.md` stopped at build 46. | **Fixed:** back-filled builds 47–50 from `DESIGN_FIX_2026-09-20.md`; 51–52 are reconstructed from source and archive times and marked as such. |
| 11 | P3 | Unreferenced view files still compiled into production. | **Fixed:** 16 files moved to ignored `build/removed-dead-views-2026-09-23/`, then omitted from the regenerated project. `HomeView.swift` was retained because it contains the live `NativeDeviceView`. |
| 12 | P3 | Archive warnings: misleading `ImplicitStrongCapture` sites, iOS 27 audio/AVAudioSession and share-extension deprecations, and deprecated `UIRequiresFullScreen`. | **Fixed:** updated callback ownership, migrated the SDK calls and removed the obsolete plist setting. Latest production build has no source or deprecation warnings; its two remaining warnings are for intentionally absent bundled model assets. Audio behavior still needs device verification. |
| 13 | P3 | `BundledVLM` and the FastVLM `.mlpackage` are not bundled (46 MB IPA), so Lens downloads ~520 MB on first use. This is intended for the public-source build. | Informational; recorded in `CHANGELOG.md`. |
| 14 | P3 | The HTTP header parser requires `": "`, so a client sending `Authorization:Bearer …` without the space fails auth. | Open. Compatibility nit. |

### Verified healthy

- Privacy manifest declares UserDefaults (CA92.1), file timestamp (C617.1),
  disk space (E174.1) and boot time (35F9.1). No tracking or collection.
- Logging: no prompts, output, transcripts or keys reach `Diagnostics` or
  `os.Logger`. The seven `print` calls are resource/bundle diagnostics only.
- Conversations, diagnostics, RAG index and recovery state are written with file
  protection. Every download site marks model files excluded from backup.
- Local API: opt-in, Keychain bearer key, constant-time SHA-256 comparison,
  lockout, 4 MB request cap, 15 s read deadline, CORS allowlist off by default,
  stops on background.
- Info.plist usage strings, entitlements (app group, iCloud, increased memory,
  extended VA) and the share extension match the release script's expectations.

## API server page (LAS redesign)

`IOSLocalLLM/Views/Bridge/LocalAPIServerView.swift` adapts the
`/Users/m/Desktop/OnDeviceLAS` homepage (`LocalAPIServerView` and
`CoreAIDashboardView`) to this app's native language: public `ODPalette` /
`ODLayout` tokens, system type, hairline surfaces, uppercase caption section
headers and the existing tinted lifecycle capsule.

| LAS element | Here |
| --- | --- |
| Network banner + live parser | The status card gains a live activity line (waiting / answering with tok/s / loading / can't answer yet). It uses the native `waveform` symbol effect and pauses under Reduce Motion. |
| Device health dashboard | *Device* strip: thermal, app memory, free storage from `ODStore.metrics`. A dash means unavailable. Stacks vertically at large text. |
| Model runtime card | Model row keeps Choose / Load and adds **Unload**, behind the same voice-conflict confirmation as model changes. |
| Connection URLs + API key | OpenAI `/v1` and shared Ollama·Anthropic origins per LAN address, plus localhost. Key reveal / copy / **rotate with confirmation**. Hidden again when the scene leaves active. **Share connection** carries a trust warning. |
| Linux quick start | Inline *Quick start* with an OpenAI / Anthropic / Ollama segmented picker. The key is masked unless revealed; *Copy with API key* always copies a working command. Replaces the "Connect a client" sheet. |
| Developer endpoints | *Endpoints* catalog listing exactly the 8 routes `LocalAPIServer` answers, with copyable URLs. LAS-only routes (`/v1`, `/api/ps`, `/api/version`) are deliberately absent. |
| Compatibility toggles | Not ported: this app has no reasoning, parallel-call or strict-schema settings, and tool calling turns on per request when `tools` is present. Adding dead switches would misrepresent the server. The real, previously hidden **Nearby devices** (AWDL) setting is exposed instead; changing it restarts a running listener. |

All existing `api.*` accessibility identifiers are preserved. New ones:
`api.activity`, `api.health`, `api.model.unload`, `api.key.rotate`,
`api.share`, `api.client.example`, `api.endpoint.copy`, `api.peerToPeer`.

## Verification

| Check | Result |
| --- | --- |
| `scripts/validate_open_source.sh` | ✅ passed |
| `scripts/test_studio_policies.sh` | ✅ 17/17 |
| `scripts/verify_zoo_catalog.sh` | ✅ all invariants |
| `swift test --package-path Packages/VoiceAgentOrb` | ✅ 25/25 |
| `git diff --check` | ✅ clean |
| Production app, Debug, generic iOS, signing off | ✅ `BUILD SUCCEEDED` after all changes (`build/audit-52/production-build-fixes2.log`). No Swift or SDK deprecation warnings; two expected missing-model-asset warnings remain. |
| QA `APIServerWorkspaceTests` (4, incl. new unload/nearby-devices test) | ✅ 4/4 first run, iPhone 17 Pro Max iOS 27 simulator (`build/audit-52/api-ui-tests.log`) |
| QA `BriefPresentationMatrix` flows that visit the API page | ✅ 2/2 (`build/audit-52/matrix-tests.log`) |
| HTTP parser overflow, standalone old vs new | ✅ old SIGTRAP (133), new `nil` |
| Auth throttle, standalone Swift check | ✅ failing host locks, another host stays open, lock expires and success resets failures |
| New `LocalAPIServerTests` parser and throttle regressions | Compile with the app. Not executed: the app test target needs the device-only Core AI runtime. |

Screenshots (11 states: light, dark, large type, running, generating, starting,
failed, model loading, no model): `build/native-ui-evidence/api-server-las/`.
These are fixture renders, not hardware evidence.

## Before the next archive

1. Commit the tree (finding 1).
2. Archive build 53 with `scripts/build_sideload_ipa.sh build/releases`.
3. On the paired iPhone: the build 42 follow-ups; the Round 2 physical gate;
   dark-mode status bar; Image studio → Share → Save Image; API server
   start → curl from a Mac → rotate key → old key rejected.
4. Confirm the migrated dictation and playback paths and audio interruption
   recovery on the phone. Findings 8–12 are code-complete but this audio gate
   remains open.
