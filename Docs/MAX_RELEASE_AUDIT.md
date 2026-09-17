# OnDevice Max — release audit

Audit of the OnDevice Max fork ahead of its first sideload IPA. Scope: fork
identity integrity, release packaging chain, privacy and licensing, and the
defects found and fixed during this pass.

Root `RELEASE_AUDIT.md` is deliberately **left as the upstream OnDevice Core
record**. It documents Core builds 1, 6 and 7 with their real sizes and
SHA-256 digests. Renaming those artifacts to Max would have fabricated release
history for binaries that never existed, so that file is unmodified.

Audit date: 2026-09-17
Base commit: `b6cf41a` (shared with `main`)
Branch: `ondevice-max` (a linked worktree at `/Users/m/Desktop/OnDeviceMax`)

## Identity

The fork must not collide with OnDevice Core when both are installed. Every
identifier was verified end to end — `project.yml`, the generated project, all
four entitlements files, `Info.plist`, and the runtime constants that have to
agree with the entitlements.

| Item | Value |
| --- | --- |
| Project / workspace / scheme | `OnDeviceMax` |
| `PRODUCT_NAME` (app) | `OnDeviceMax` |
| `PRODUCT_NAME` (share extension) | `OnDeviceMaxShare` |
| `PRODUCT_MODULE_NAME` | `IOSLocalLLM` (unchanged, see note) |
| Display name | `OnDevice Max` |
| Bundle ID (app) | `com.mesutcydev.ondevicemax` |
| Bundle ID (share) | `com.mesutcydev.ondevicemax.share` |
| Bundle ID (unit tests) | `com.mesutcydev.ondevicemax.tests` |
| Bundle ID (UI tests) | `com.mesutcydev.ondevicemax.uitests` |
| App Group | `group.com.mesutcydev.ondevicemax.shared` |
| CloudKit container | `iCloud.com.mesutcydev.ondevicemax` |
| URL scheme | `ondevice-max` |
| Version | 1.0.0 (10) |
| Minimum OS | iOS 27.0 (Catalyst `MACOSX_DEPLOYMENT_TARGET` 27.0) |

`PRODUCT_MODULE_NAME` stays `IOSLocalLLM`. That is the Swift module name behind
`@testable import IOSLocalLLM` in 44 unit-test files, and
`Docs/FORK_CONFIGURATION.md` explicitly allows internal module names, queue
labels and keychain service names to remain stable. Changing it would have
touched every test file for no fork-isolation benefit — Swift module names are
not part of the install identity.

### Runtime constants verified against the entitlements

These must match the entitlements or the feature silently fails at runtime
rather than at build time, so each was checked individually:

| Constant | File | Agrees with |
| --- | --- | --- |
| `appGroupID` | `Models/AppBridge.swift` | app group entitlement |
| `appGroupID` | `ShareViewController.swift` | share-extension entitlement |
| `url.scheme == "ondevice-max"` | `Models/AppBridge.swift` | `CFBundleURLSchemes` |
| `urlScheme` | `ShareViewController.swift` | `CFBundleURLSchemes` |
| `CKContainer(identifier:)` | `Services/CloudSyncService.swift` | iCloud container |
| `SpotlightIndexer.domain` | `Services/SpotlightIndexer.swift` | fork-local namespace |
| background `URLSession` id | `Services/BackgroundDownloadCoordinator.swift` | fork-local namespace |
| keychain services | `HFTokenStore`, `KeychainStore`, `BridgePairingStore` | fork-local namespace |
| log subsystems / signposts | `Diagnostics`, `VoicePerformanceSignposts` | fork-local namespace |

Because the app group, CloudKit container, keychain services and Spotlight
domain all carry the `ondevicemax` prefix, the two products share no container,
no keychain item and no Spotlight domain. `AppBridge` reads and
`ShareViewController` writes through the same `group.…ondevicemax.shared`
identifier, so the share-extension handoff works within Max and cannot land in
Core.

Internal UserDefaults keys under the `ioslocalllm.*` namespace were left
unchanged on purpose. Each app has its own sandbox, so the shared key prefix
cannot collide across two installed products, and `Docs/FORK_CONFIGURATION.md`
permits it for a private development build.

## Packaging chain

`scripts/build_sideload_ipa.sh` is the source of truth for the release
contract. All eight steps were verified against this fork.

- Step 1 regenerates from `project.yml` and runs `pod install`, so
  `project.yml` — not `Info.plist` — is authoritative. Any value that only
  lives in `Info.plist` is overwritten during the release build. This is why
  the privacy-string fix below was applied to `project.yml`.
- Step 3 archives the `OnDeviceMax` scheme for `generic/platform=iOS`, which
  produces `OnDeviceMax.app` with the `OnDeviceMax` executable. The script's
  `otool -L "$APP/OnDeviceMax"` assertion matches the actual product.
- Step 5's assertions all hold: bundle ID, display name, version 1.0.0, build
  10, minimum OS 27.0, `PrivacyInfo.xcprivacy`, `PlugIns/OnDeviceMaxShare.appex`,
  `Frameworks/llama.framework`, `Frameworks/whisper.framework`, and CoreAI
  linkage.
- Step 6 ad-hoc signs with `IOSLocalLLM-PCC.entitlements` plus the
  share-extension entitlements.
- Step 7 requires exactly `Payload/` at the IPA root, no
  `embedded.mobileprovision`, and five entitlement keys on the signed app.

Every external command the chain needs is present (`xcodegen`, `pod`,
`xcodebuild`, `codesign`, `ditto`, `plutil`, `unzip`, `zip`, `shasum`, `otool`,
`python3`, `jq`, `rg`). Both Python helpers compile, and all six release shell
scripts pass `bash -n` and are executable.

`scripts/collect_sideload_notices.py` aborts below a 10-file license inventory;
this fork resolves 14, so the license bundle step will succeed.

### Entitlements versus the step 7 contract

The five keys the script requires are all present in
`IOSLocalLLM-PCC.entitlements`: increased memory limit, extended virtual
addressing, Private Cloud Compute, application groups, and iCloud container
identifiers. The base `IOSLocalLLM.entitlements` correctly omits PCC — that key
is scoped to `sdk=iphoneos27.*` only, so iOS 18–26 and Xcode 26 builds keep a
local-only binary. Catalyst uses its own entitlements file with App Sandbox.

`Info.plist` also carries the two file-sharing flags step 7 asserts
(`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`), plus
`ITSAppUsesNonExemptEncryption: false`.

## Privacy and security

- Secret scan (the validator's own pattern, covering AWS/GitHub/HF/OpenAI keys
  and private-key blocks): no matches.
- No tracked signing material — zero `.p8`, `.p12`, `.cer`, `.pem`,
  `.mobileprovision`, `ExportOptions.plist`, `.xcarchive` or `.ipa` files.
- No tracked model weights or generated frameworks (`.gguf`, `.safetensors`,
  `.mlpackage`, `.mlmodelc`).
- No App Transport Security exception dictionary, so network access stays
  HTTPS-only. This matches the `AGENTS.md` invariant that network access must
  remain explicit and that local inference must not silently reach a remote
  service.
- HF tokens are stored as `kSecClassGenericPassword` with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never in UserDefaults.
  The same accessibility class is used by `KeychainStore` and
  `BridgePairingStore`.
- No prompt, response, token or API-key logging found in the Swift sources.
- All five usage-description strings are present and non-empty.
- `LocalAPIManager.shared.stop()` is called on the `.background` transition in
  `LifecycleController`, preserving the invariant that the local API stops when
  the app backgrounds.

## Licensing and provenance

All required notice files are present: `LICENSE` (MIT, upstream copyright
intact), `THIRD_PARTY_NOTICES.md`, `PROVENANCE.md`, `ASSET_PROVENANCE.md`,
`REUSE.toml`, `LICENSES/Apple-Sample-Code-License.txt`, the Voice and
StableDiffusion licenses, and `Packages/VoiceAgentOrb/{LICENSE,NOTICE}`.

Upstream attribution was preserved rather than rebranded. `THIRD_PARTY_NOTICES.md`
and `PROVENANCE.md` still attribute the original iOS Local LLM project, and
`LegalDocuments.swift` still records that OnDevice is a modified distribution
derived from the upstream MIT project. That is what the licensing rules require
— the fork identity changes, the attribution does not.

`TRADEMARKS.md` states that forks must use their own identity and artwork and
must not imply endorsement. The new product name and bundle namespace satisfy
the identity half. The artwork half is still open — see below.

## Defects found and fixed

### 1. Validator compared lockfiles through retired paths (build-breaking)

`scripts/validate_open_source.sh` compared the two committed SwiftPM lockfiles
via `IOSLocalLLM.xcodeproj` / `IOSLocalLLM.xcworkspace`. Those paths do not
exist — the project has been `OnDeviceCoreAIStudio.*` upstream and is
`OnDeviceMax.*` here. The check aborted on a missing file before ever reaching
the version, secret and action-pinning checks, so the whole hygiene gate was
dead. Fixed to read the generated `OnDeviceMax.*` paths.

The upstream working tree carries an equivalent uncommitted fix pointing at
`OnDeviceCoreAIStudio.*`; because this fork was created from HEAD, it inherited
the broken version. Both lockfiles are byte-identical, so the check passes once
the paths are right.

### 2. Stale CodeLens-era privacy strings (release-blocking)

All five usage descriptions described a different product. The camera string
claimed the app captures "live video of your terminal or code editor for
real-time analysis" — inherited from the CodeLens project this repo was derived
from. Max's Lens reads text, documents and scenes. The microphone, photo and
speech strings were similarly describing a chat-composer-first product rather
than the voice-conversation product that ships.

This is the highest-severity finding in the audit. Usage strings are what users
see in the system permission dialog, and a dialog that misdescribes the purpose
is both a user-trust failure and an App Review rejection risk. It survived in
both `project.yml` and `Info.plist`, and because step 1 of the IPA script
regenerates the plist, fixing only the plist would have been silently reverted
at release time. Fixed in `project.yml` (the source of truth) and propagated
with `xcodegen generate`.

### 3. Legal copy named the wrong feature (user-facing)

`LegalDocuments.swift` told users that chat conversations "with the Coding
Assistant" are stored locally, and the Qwen3 attribution called it "the default
on-device coding assistant". No view in the app uses that name — the UI calls it
Assistant throughout. The upstream project has the same correction in its
uncommitted working tree; applied here to match.

### 4. Hardcoded User-Agent version (correctness)

`CoreAIHFDownloadManager` sent `OnDeviceCoreAIStudio/3.2.6` as its User-Agent in
two places while the app is versioned 1.0.0. The version was frozen in the
string and went stale the moment `project.yml` moved on, so every Hugging Face
request announced a version the shipped build did not have. Replaced with a
single `CoreAIDownloadUserAgent.value` that reads
`CFBundleShortVersionString` from the bundle, matching how
`SystemSnapshot.appVersion()` resolves it.

### 5. Release metadata disagreed with `project.yml` (validator-blocking)

At HEAD, `CITATION.cff`, `SBOM.spdx.json` and `CHANGELOG.md` all declared 3.2.6
while `project.yml` declared 1.0.0. The validator cross-checks these and failed.
This is a pre-existing inconsistency in the base commit, not something the fork
introduced — the upstream working tree carries the same uncommitted 1.0.0 bump.
Aligned all three to 1.0.0, including the SBOM document name and namespace so
the file is internally consistent, and added a `[1.0.0]` CHANGELOG entry
recording the fork and the fixes above.

### 6. Every documented build command named a nonexistent scheme (all repos)

`AGENTS.md`, `README.md`, `SETUP_INSTRUCTIONS.md` and `Docs/VALIDATION.md` all
instructed readers to run `xcodebuild … -workspace IOSLocalLLM.xcworkspace
-scheme IOSLocalLLM` and to `open IOSLocalLLM.xcworkspace`. No such workspace or
scheme exists — the scheme has been `OnDeviceCoreAIStudio` upstream and is
`OnDeviceMax` here. Every one of those commands fails as written, in the
original repository too; this is pre-existing, not fork-introduced, but it is the
first thing a new contributor runs. Corrected all four documents to the real
`OnDeviceMax` workspace and scheme, and split `llms.txt`'s conflated
"Swift module and Xcode scheme: IOSLocalLLM" line into two accurate ones (the
module really is `IOSLocalLLM`; the scheme is `OnDeviceMax`).

`SETUP_INSTRUCTIONS.md` and `Docs/VALIDATION.md` also claimed an "iOS 18 or
newer Simulator" was sufficient, while the deployment target is iOS 27 and the
simulator SDK cannot even resolve `CoreAI`. Both now state the device
destination and explain the constraint, so the documented verification path is
one that actually works.

### 7. `Podfile.lock` checksum

`pod install` rewrote `PODFILE CHECKSUM`. This is correct and expected, not a
defect: the Podfile names the regenerated `OnDeviceMax.xcodeproj`, so the
checksum must change. `SETUP_INSTRUCTIONS.md` lists `Podfile.lock` among the
files to commit after regeneration.

## Reverted: fabricated release records

The initial rebrand was a mechanical sweep across 44 tracked files. That was
right for identifiers and wrong for three documents that record *facts about
OnDevice Core*, and all three have been reverted to upstream content:

- **`altstore/source.json`** — the sweep renamed the OnDevice Core app entry to
  OnDevice Max and rewrote its download URL to a release tag that does not exist,
  while leaving `size` (51,962,265) and `sha256` (`55099346…`) pointing at
  Core's real published IPA. Publishing that would have made AltStore download a
  nonexistent artifact and fail hash verification against Core's bytes. The
  manifest format validator passed throughout because it only checks shape, not
  truth — a hash mismatch is invisible to it.
- **`RELEASE_AUDIT.md`** — builds 1, 6 and 7 were renamed to Max artifacts while
  keeping Core's real sizes and SHA-256 digests, inventing release history for
  binaries that were never built.
- **`altstore/README.md`** — described the manifest above, so it inherited the
  same fiction.

The lesson recorded here: a rename sweep must exclude documents that assert
checksums, sizes, download URLs or dated build history. Those describe specific
existing artifacts and can only be updated by producing new ones. A genuine Max
AltStore entry needs the Max IPA's own size and SHA-256 after it is built.

Two prose corruptions from the same sweep were also fixed: `README.md` and
`llms.txt` renamed "**OnDevice CoreAI Local API Server**" — a separate beta
product in the product-line table — to "OnDevice MaxAI Local API Server", which
neither describes a real product nor reads as English.

## Housekeeping

`scripts/verify_ipa_identity.sh` exists only as an untracked file in the
upstream working tree, so the HEAD-based fork did not have it. Ported and
rebranded (its default expected bundle ID is now `com.mesutcydev.ondevicemax`);
it differs from upstream by that one line. The `scripts/edge0_*` untracked files
were deliberately not ported — they belong to the Edge0 work-in-progress that
this fork was scoped to exclude.

`.gitignore` had no Python cache coverage, so the `__pycache__` directory that
the release tooling produces would have been committed. Added `__pycache__/` and
`*.py[cod]`, and removed the stray directory created during this audit.

## Outstanding items

**Blocking the IPA build.** Four untracked files under
`IOSLocalLLM/Views/Studio/` (`StudioComposer.swift`, `StudioChatPieces.swift`,
`StudioAddSheet.swift`, `StudioTokens.swift`) sit inside the xcodegen source
path, so they compile into the target, and `CodingAssistantView.swift` has been
rewired to mount them.

When this audit first ran, the three view files referenced five symbols that
existed nowhere in the target — `T.studio`, `StudioRadius`, `StudioSpacing`,
`StudioMonoLabel`, `StudioHairline` — so any Release archive failed to compile.
`StudioTokens.swift` has since landed and now defines all five (`T.studio` as an
extension on `KoduTheme`), which clears that specific error. The design work is
still actively in progress, however, so the tree has not yet been shown to
compile clean as a whole and an archive should not be attempted until it has.

The fork's own baseline build (device, Debug, signing disabled) succeeded before
these files existed, and nothing outside the Studio layer and its one rewired
host view is implicated.

Before archiving, confirm the design work compiles end to end with a device
build; the simulator destination cannot be used for this (see the `CoreAI`
simulator-SDK constraint noted under "Verification performed").

**Open, non-blocking:**

- **App icon and artwork are byte-identical to OnDevice Core.** Both
  `AppIcon.appiconset` and `AppIconClassic.appiconset` match Core exactly, and
  the whole asset catalog is unchanged. `TRADEMARKS.md` asks forks to use their
  own identity *and artwork*, so Max needs its own icon before public
  distribution. Nothing in the build or packaging path depends on this.
- **`llama.xcframework` has no Mac Catalyst slice.** `project.yml` sets
  `SUPPORTS_MACCATALYST: YES`, but the framework ships only `ios-arm64` and
  `ios-arm64_x86_64-simulator`, while `whisper.xcframework` does include a
  Catalyst slice. A Catalyst archive would fail to link llama. Identical in both
  repos, so pre-existing — and the IPA script builds `generic/platform=iOS`
  only, so the iOS artifact is unaffected.
- **`ThirdParty/` is untracked.** `.gitmodules` declares llama.cpp and
  whisper.cpp as submodules, but the base commit contains no gitlink entries and
  zero tracked files under `ThirdParty/`. It is ignored via the upstream repo's
  `.git/info/exclude`, which linked worktrees share — not via `.gitignore`. A
  fresh clone of this fork therefore cannot reproduce the native frameworks from
  Git alone; they must be rebuilt with `scripts/build_native_frameworks.sh` as
  `SETUP_INSTRUCTIONS.md` documents. For this working copy the artifacts were
  cloned locally with APFS copy-on-write, which is why the fork builds without a
  multi-hour framework rebuild.
- **`docs` still point at upstream release assets.** `Docs/RELEASE_VERIFICATION.md`
  and `README.md` reference `v3.2.6` GitHub source-release tags and the
  `ios-local-llm` repository slug. Accurate for the upstream source distribution
  this fork derives from, but worth revisiting if Max ever publishes its own
  source releases.

## Verification performed

| Check | Result |
| --- | --- |
| `scripts/validate_open_source.sh` | pass |
| `scripts/validate_altstore_source.sh` | pass |
| `swift test --package-path Packages/VoiceAgentOrb` | 25 tests, 6 suites, pass |
| `xcodegen generate` (twice, for idempotency) | project + scheme regenerated, identity preserved |
| `bash -n` on all six release scripts | pass, all executable |
| `python3 -m py_compile` on both Python helpers | pass |
| `xcrun swiftc -parse` on modified Swift files | pass |
| `plutil -lint` on both `Info.plist` and all four entitlements | pass |
| JSON validity (`SBOM`, `altstore`, `codemeta`) | pass |
| Device build, Debug, signing disabled | succeeded at baseline (before Studio files) |
| License inventory for the notices collector | 14 files (needs ≥10) |
| Residual old identifiers in tracked files | none (one upstream icon URL retained) |

The simulator destination cannot be used for a full verification build:
`CoreAI.framework` exists in the iPhoneOS 27 SDK but not in the iPhoneSimulator
27 SDK, so the vendored `CoreAIShared` package fails to resolve `import CoreAI`
for any simulator target. This is a constraint of the iOS-27 Core AI edition and
applies to the upstream project identically. Device builds are the correct
verification path, matching `Docs/RELEASE_VERIFICATION.md`.

## Fork isolation confirmed

Because this fork is a linked worktree of the upstream repository, the original
checkout was verified untouched: same HEAD (`b6cf41a`), same branch (`main`),
nothing staged, and zero occurrences of any Max-authored identifier, string or
path in its tracked or untracked files. The only write to the original
repository is the worktree registration inside its `.git/` directory, which is
inherent to the branch/worktree strategy and touches no source, config or
tracked file. No symlink in the fork resolves into the original tree, so the two
working copies cannot cross-contaminate.

---

# Release-audit pass — sideload IPA 1.0.0 (10)

Second audit, run after the Studio/Lens redesign landed. It closes the two items
the first pass left open (the whole tree now compiles clean; a Release archive,
signed IPA and final verification have all completed) and records one new defect
found by the repository's own tooling.

## Defect found and fixed — catalog understated a pack size

`zoo-minicpm5-1b` declared `approxDownloadBytes: 1_092_313_209` while the pinned
upstream tree now totals 1_158_613_345 bytes — 6.1% drift, above the verifier's
2% ceiling, so `scripts/verify_zoo_downloads.py` failed and the release chain
would have aborted at step 2. The value understates the download shown in the
Models browser and feeds `MemoryAdvisor`'s admission math. The reference working
tree already carried the corrected number; it was adopted verbatim
(`IOSLocalLLM/Models/CoreAIZooCatalog.swift`). All 21 packs now verify.

## Structure parity with the reference (checked file-by-file)

- `build_sideload_ipa.sh`, `package_adhoc_sideloadable_ipa.sh`,
  `verify_foundationmodels_symbols.sh`, `verify_zoo_catalog.sh` are byte-identical
  to the reference apart from product identity. `verify_ipa_identity.sh` and
  `collect_sideload_notices.py` differ by one identity line each; the four
  entitlements files differ only in the app-group / iCloud container strings.
- The finished IPA was compared against the reference's newest Core IPA. Two
  deliberate, verified deltas exist and both make Max _cleaner_:
  1. No empty `BundledVLM/` entry. No weights ship in either product; the fork's
     build script skips creating the directory and `BundledVLMInstaller` falls
     back to the runtime GGUF download either way.
  2. No root-level `tokenizer.json` / `vocab.json` / `merges.txt` /
     `preprocessor_config.json`. Those are gitignored leftovers in the reference
     working tree (`.gitignore:42-45`) that its builds sweep in (~16 MB). No
     bundle-loading code path reads them — every consumer (`LocalModelFileValidator`,
     `ModelCatalogTypes`, `HFModelDownloadManager`, `VLMCapabilities`) reads model
     directories on disk. Max ships without the dead weight.

## Release chain executed

`./scripts/build_sideload_ipa.sh build/releases` — all 8 steps passed:
regenerate + `pod install`; 21/21 catalog packs verified over the network;
unsigned device Release archive (`** ARCHIVE SUCCEEDED **`); FoundationModels
dyld-symbol preflight; archive identity/resource assertions; 36 license and
notice files bundled; ad-hoc signing with the exact app + extension
entitlements; final verification (zip integrity, Payload-only root, deep-strict
signatures, file-sharing flags, five app entitlement keys, extension app-group).

## Artifact

- `build/releases/OnDeviceMax-sideload-entitled-1.0.0-10.ipa` — 48,190,673 bytes,
  SHA-256 `16ca343e4457ebe468a108f2fa8bcfa48bc9bcbff37d41e9fc45a049e67e55d4`,
  plus the `…-latest.ipa` copy, `OnDeviceMax-1.0.0-10-verification.json` and the
  extracted `OnDeviceMax-1.0.0-10-THIRD-PARTY-NOTICES.txt` in the same folder.
- Entitlements intact on the signed binary: increased-memory-limit,
  extended-virtual-addressing, private-cloud-compute, app group
  `group.com.mesutcydev.ondevicemax.shared`, iCloud container
  `iCloud.com.mesutcydev.ondevicemax` (+ CloudKit). Extension carries the app
  group. No provisioning profile embedded — installer re-signing required.
- Session checks: Studio policy checks 17 passed; VoiceAgentOrb package 25 tests
  in 6 suites passed; `validate_open_source.sh` + `validate_altstore_source.sh`
  passed; `xcodegen generate` idempotent.

## Still open (none block the local IPA)

- App icon and artwork remain byte-identical to Core; `TRADEMARKS.md` asks forks
  for their own artwork before public distribution.
- `altstore/source.json` still truthfully records Core's release; a genuine Max
  entry needs the published URL for this IPA's size (`48,190,673`) and SHA-256
  (`16ca343e…55d4`).
- Physical-device runtime validation was not performed (requires installer-side
  re-signing and a device).
