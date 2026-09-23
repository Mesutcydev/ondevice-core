# Build 45 pre-release audit — 2026-09-20

Producer-side audit run immediately before packaging build 45. Build 45 is the
first IPA to contain the Round 2 refinement pass plus the same-day
code-quality fixes; this audit re-verifies the tree end to end before the
archive.

## Scope: what is in build 45

- **Round 2 refinement pass** (post-build-44): camera/voice ownership
  serialization, persistent voice accessory, bottom geometry, conflict
  confirmation, Lens capture-review flow, chat snippets, voices/image/models/
  device polish. 40 changed files listed in
  [ROUND2_IMPLEMENTATION.md](ROUND2_IMPLEMENTATION.md).
- **Post-Round-2 fixes** (this session and the 13:17 pass):
  `FastVLM.swift` logs a diagnostics fault before its verified-unreachable
  trap; `SettingsView.swift` Whisper STT block fails with a descriptive
  precondition instead of force-unwrapping an arbitrary catalog model;
  `LensFramePreparer.swift` dead duplicated `modelMinimumSide` removed (the
  13:17 pass had already hoisted the single source of truth to
  `VLMCapabilities.minimumProcessorSide`); `SETUP_INSTRUCTIONS.md` documents
  the stale-`.build` metal-toolchain failure mode; `CHANGELOG.md` records
  builds 43/44 and these fixes.

## Verification results

| Check | Result |
| --- | --- |
| `scripts/validate_open_source.sh` | ✅ passed |
| `scripts/test_studio_policies.sh` | ✅ 17/17 |
| `scripts/verify_zoo_catalog.sh` | ✅ all catalog invariants hold |
| `scripts/verify_zoo_downloads.py` | ✅ all 21 Core AI packs downloadable (HTTP 206) |
| `swift test --package-path Packages/VoiceAgentOrb` | ✅ 25/25 (25 tests, 6 suites) |
| `git diff --check` | ✅ clean |
| Fingerprint drift vs `build/round2/final-source-hashes.json` | 9 files, all accounted for (see below) |
| Entitlements / share extension / `Pods` / `Podfile.lock` | unchanged vs build 44 |
| Flaky-test reproduction | ✅ passes 2/2 focused reruns (see below) |

### Fingerprint drift accounting

Nine files differ from the Round 2 final hashes; none are unexplained:

- 12:03 batch — `ContentView.swift`, `WorkbenchSelectionObserver.swift`,
  `ODWorkbench.swift`, `ODStore.swift`: late Round 2 changes, covered by the
  subsequent final verification runs (`build-qa-final.log` TEST BUILD
  SUCCEEDED 12:06, `build-production-final.log` **BUILD SUCCEEDED** 12:08,
  `verification-final-large.log` TEST EXECUTE SUCCEEDED 12:11).
- 13:17 batch — `LensInferenceLoop.swift`, `VLMCapabilities.swift`: the
  `minimumProcessorSide` single-source-of-truth hoist.
- This session — `FastVLM.swift`, `SettingsView.swift`,
  `LensFramePreparer.swift`: the three code-quality fixes above.

The 13:17 and later Swift edits have not been compiled by any harness; the
build-45 Release archive is their first compiler gate.

### Flaky test investigation

`APIServerWorkspaceTests.testPageNavigationRetainsDraftAndServerControls`
failed at 12:13 on the compact (`iPhone 17 iOS27`, 402 pt) simulator while the
large-width run passed. Failure mode: interactive model-picker sheet dismissal
did not complete, the `api.enabled` switch was not hittable afterwards, and
the status never reached "Stopped" within 5 s. The test's own comment
documents that synthesized events do not reliably drive iOS interactive sheet
dismissal.

Reproduced twice this session on the same simulator against the unchanged QA
harness (`build/round2/repro-api-compact.log`,
`repro-api-compact-2.log`): **2/2 passes**, ~33 s each. Verdict: flaky
interactive-dismissal timing, not a Round 2 regression — consistent with the
build-43 pattern of initial-run flake with passing focused reruns.

## Open gates carried forward (unchanged by this audit)

1. **Build 41 first-token stall** — follow-ups 1–4 in
   [RELEASE_BLOCKER_AUDIT_2026-09-20.md](RELEASE_BLOCKER_AUDIT_2026-09-20.md)
   remain the real release gate; build 42's on-device success does not prove
   the root cause.
2. **Round 2 physical release gate** — the ten device checks in
   [ROUND2_IMPLEMENTATION.md](ROUND2_IMPLEMENTATION.md) §"Physical release
   gate" are unverified; the paired iPhone was unavailable at the time. Build
   45 is the first artifact able to run them.
3. Full `xcodebuild test` app suite not run (device-only CoreAI); audit is
   static checks, fast validators, QA harness and the Release archive compile.

## Verdict

No blocker to producing build 45 as a profile-less, re-signer-ready **test
artifact** — same status as builds 43/44. Physical-device installation and the
carried-forward gates above remain the path to calling any build a release.

## Build 45 artifact

- IPA: `build/releases/OnDeviceMax-sideload-entitled-1.0.0-45.ipa`
- Size: 46,279,093 bytes.
- SHA-256: `ed1b394175ca154a4d573d8e872e7e0f27d7437e8ea884bc0281ecf459a58b18`.
- Release script completed all eight stages: `build/release-45.log`. The
  Release archive doubles as the first compiler gate for the 13:17 hoist and
  this session's three Swift fixes — it passed.
- Independent verification: `build/releases/OnDeviceMax-45-verification.json`.
  Payload structure, bundle identity (`com.mesutcydev.ondevicemax` 1.0.0-45)
  and the complete signed app/share-extension entitlement dictionaries match
  the source plists exactly. No source file changed during the archive.
- The profile-less IPA requires installer-side re-signing. No build 45
  physical-device installation is claimed; the carried-forward gates above
  apply to this artifact.
- Build-environment note for repeatability: the packaging script requires
  `USER` and a UTF-8 locale (`LANG`/`LC_ALL`) in the invoking shell, or
  CocoaPods aborts in stage 1 ("Couldn't find current username" /
  ASCII-8BIT normalization error).
