# OnDevice Max App Store compliance audit

Audit date: 2026-10-01. Candidate: iOS app, version 1.0, build 1.

**Verdict: not ready for public App Store submission.** The source and compiled bundle have
received a compliance review and focused fixes, but licensing, content safety,
published privacy information, and production device evidence remain open.
The fresh OnDevice Max record is Apple ID `6818199563`, with the exact bundle
ID. Both signed local bundles verify as 1.0 (1); the upload and processing
completed successfully. Apple's Build Metadata reports Validated, version
1.0.0, build 1, and the correct owner-team entitlements. The build belongs to
the internal Me group. Earlier build 79 remains in history; it completed before
the later version/build request. No public App Store review submission, Beta
App Review submission, tester addition, or remote privacy-policy publication
was performed by the agent.

This report covers the current working tree, including changes already present
before this audit. It does not certify every downloaded checkpoint, every
device, a Mac Catalyst release, or the account's portal settings. A successful
compile is evidence of compilation, not App Review acceptance.

## Confirmed problems corrected locally

| Finding | Change and evidence | Remaining check |
| --- | --- | --- |
| Custom App Store review funnel | Deleted `ReviewPromptService.swift`, its sheet, and associated translations. The old flow screened for positive sentiment and directed satisfied users to App Store reviews. No custom review prompt or replacement review SDK remains in the searched production source. | Check the signed candidate and future changes for reintroduction. |
| Debugging memory in public distribution | Added separate App Store entitlements and selected them for Release in `project.yml`. The debugging memory entitlement is absent from the exported app and extension; signed distribution verification passed. | Preserve the check on future candidates. |
| Unverified PCC capability in Release | Default App Store entitlements omit PCC. A separate variant can be selected explicitly after the managed grant is verified. | Confirm Apple authorization before offering PCC in the public candidate. |
| Extension opening the containing app through `UIApplication` | Replaced the responder-chain workaround with an atomic App Group inbox and a native receipt. The main app consumes the queued share when opened or foregrounded. Enabled `APPLICATION_EXTENSION_API_ONLY`. | Test an actual share from another app on an iPhone with distribution profiles. |
| Extension privacy manifest missing | Added and bundled an extension manifest. Required file timestamp access is declared for its own/App Group files. | Final archive validation and generated privacy report. |
| Overbroad privacy claims | Updated the local privacy policy, in-app legal text, retention description, optional network behavior, and legal version. Added the file timestamp reason for user-selected model folders. | Publish the corrected public policy and complete accurate App Store privacy answers. |

Apple disallows custom review prompts under 5.6.1; discovery manipulation is
addressed by 5.6.3. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
The debugging memory entitlement is limited to development and specified
internal/testing distribution. [Apple entitlement guidance](https://developer.apple.com/help/glossary/increased-debugging-memory-limit/).
Extensions must use extension-safe APIs. [Apple extension guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html).

## Further corrections in this pass

Image generation remains enabled. Settings now has optional parental controls:
a six-digit parent PIN, salted PBKDF2 derivation, device-only Keychain storage,
persistent retry delays, and PIN-required restriction changes/removal. Clearing
app data preserves the controls. Image Studio and chat tools refuse restricted
requests; changing the restriction cancels active work, clears the displayed
result, and prevents late result publication. The active Image Studio explains
the restriction and links to PIN-protected controls. These controls do not
classify prompts or generated pixels.

The Catalyst launch legal-acceptance gate is removed; the documents remain
accessible in Settings. Full Catalyst validation is still outstanding.

Public HF, CoreAI, image, and MLX fallback downloads use/check a bundled set of
81 frozen source revisions and refuse unknown sources. Public curated catalog
rows without a source revision are excluded, including the unavailable SD 2.1
and Qwen 3.5 4B repositories. Turbo and the remaining image choices stay enabled.
This records provenance, not license eligibility or the integrity of previously
installed caches. Missing source inventory still causes downloads to refuse;
the bundle verifier requires that resource before release.

The main privacy manifest now declares retained Search History, provider-account
identifiers (User ID), and Other Data for request metadata. Linking is declared
conservatively because API credentials can associate requests with a provider
account and queries are not de-identified. Advertising tracking is false. Query
purposes include functionality and other provider uses; identifier/metadata
purposes cover authentication/security/functionality. Local parental PINs are
not transmitted. App Store Connect answers and the final privacy report still
need reconciliation. [Apple data types](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype),
[Apple collection purposes](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatypepurposes).

## Open findings that prevent a release verdict

### FastVLM rights conflict: public paths corrected

**Confirmed license conflict with the intended product use.** Apple's FastVLM
license limits the model and derivatives to research and expressly excludes
product development and commercial product/service use. A free download or a
converted mirror does not establish permission for this app's product use.
[FastVLM license](https://huggingface.co/apple/FastVLM-0.5B/blob/main/LICENSE).

Correction: public Release compiles `AppStoreModelPolicy`. Confirmed FastVLM
identities are rejected at catalog, discovery, download, load, and analysis
boundaries. Old empty/FastVLM Lens defaults migrate to SmolVLM2 GGUF. The legacy
picker row and Settings pipeline are hidden, and bundled encoder artifacts are
excluded. Debug and the explicit research sideload track remain separate.

Remaining evidence: validate replacement Lens inference on an iPhone and verify
the final signed bundle. Renamed/custom imports still need provenance review;
a string-identity guard does not certify arbitrary files.

### Youtu has an unresolved territory limitation

**Unresolved rights for worldwide distribution.** The upstream Youtu license
contains an additional territorial clause stating that it is not intended for
EU use and that this clause prevails in conflicts.
[Youtu license](https://huggingface.co/tencent/Youtu-LLM-2B/blob/main/LICENSE.txt).

Correction: the research catalog retains its source record, while the public
catalog excludes Youtu. Public download and activation guards also reject its
repository and old `coreai:zoo-youtu-llm-2b` identity. The public catalog checker
verifies that this identity cannot fall through to the custom chat path.

### The full model catalog lacks a completed rights audit

**Incomplete verification.** The checked license notices do not establish
rights for every conversion, image checkpoint, voice, and future remote
revision. Public Image Studio exposes SD/SDXL Turbo, SD 1.5, DreamShaper 8,
Segmind Vega, and SSD-1B. Commercial-use conditions for the exact selected
artifacts have not all been cleared in this audit. SD 2.1 is now excluded from
the public curated catalog because its source revision could not be verified;
the research source record remains.

Required resolution: record the exact source/revision, original and conversion
licenses, permitted product use, attribution, use restrictions, and territories
for every curated downloadable/bundled artifact. Pin approved artifacts and
preserve their notices. Do not treat an MIT runtime as permission for every
model it can execute. App Review 5.2.1 is the relevant rights rule.
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

Source evidence now records 178 model/upstream revisions in
`Docs/audits/appstore-model-license-inventory-2026-10-01.json`. The audit fetched
metadata and legal texts only. One hundred nonempty upstream license/notice
files and two required Turbo notices are preserved in `LICENSES/Models/` and
included by release notice collection. Image Studio displays the required
“Powered by Stability AI” attribution for Turbo models.

Specific pending conditions include:

- SD/SDXL Turbo: registration for commercial product use, revenue/affiliate
  eligibility or an enterprise license, and acceptable-use compliance.
  [Turbo license](https://huggingface.co/stabilityai/sd-turbo/blob/main/LICENSE.md).
- LFM 2.5: legal-entity commercial revenue eligibility and redistribution terms.
  [LFM license](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct/blob/main/LICENSE).
- Llama/Gemma/NVIDIA: artifact-specific terms and required notices. An empty
  converted NVIDIA license file is not proof of rights.
- SD 1.5/DreamShaper/Segmind: original/derivative restrictions and effective
  safety controls; a conversion card's Apache tag does not override base terms.
- Pre-existing caches and imports: file provenance/integrity. New download pins
  do not prove that old cached files match the audited revisions.

### Generated content safety remains unverified

**High risk, not a demonstrated prohibited output.** The inspected image
generation path decodes and publishes results without an identified prompt or
output content filter. Its methods named “safety filter” concern RAM fit, not
sexual, violent, or other objectionable content. No adversarial inference test
was run on an iPhone. Text models and user-imported models also need a defined
content policy.

Implemented parent-PIN controls restrict the generation feature across Image
Studio and chat tools. Wrong-PIN, restart, retry-delay, storage-error, and
restriction/unlock UI cases have passed. Image generation has not been disabled.
These controls are not a prompt or image content classifier.

Remaining resolution: validate effective controls for the public candidate,
including abusive prompts and bypass attempts, and answer the age questionnaire
from observed behavior. An adult age rating is not a substitute for controlling
prohibited content. Review rules 1.1, 2.3.6, and any applicable 4.7 obligations.
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

### Published privacy information and declarations remain incomplete

**Confirmed publication gap; data declarations unresolved.** The app's public
privacy URL still points at the upstream policy dated 2026-07-29. The corrected
local policy has not been published.
[Published policy](https://github.com/Mesutcydev/ios-local-llm/blob/main/PRIVACY_POLICY.md).

The app has optional web search/fetch, Hugging Face requests, iCloud sync, local
network APIs, and separately consented PCC. Local inference does not itself
prove “Data Not Collected.” Brave confirms query retention up to 90 days and retained account/request
metadata. Tavily describes retained queries, potential service improvement, and
limited index-provider sharing. The main manifest now declares these known
collections conservatively; final portal/report reconciliation and all enabled
destination contracts remain checks. [Brave policy](https://api-dashboard.search.brave.com/app/documentation/general/privacy-policy),
[Tavily policy](https://www.tavily.com/privacy).

Apple distinguishes on-device processing from retained off-device data and
requires considering third-party partners.
[App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).

Required resolution: publish the accurate policy, verify each enabled network
destination and consent, reconcile manifests/privacy labels, and retain
provider-specific evidence. Generate and inspect Xcode's final privacy report.

### Signed export verified; fresh App Store Connect record established

Account sign-in and owner-team signing are restored. Shipping Xcode 27
`27A266a` was installed from the Mac App Store, its iPhoneOS SDK contains CoreAI,
and the matching Metal toolchain reports installed. The beta toolchain remains
available for other project work. Apple's shipping Xcode 27 was released
2026-09-14. [Apple releases](https://developer.apple.com/news/releases/).

The configured owner team is `PUH4GMFV56`, with Admin and Certificates,
Identifiers & Profiles access. Valid owner development and distribution
identities are present. Unrelated teams were not selected. Shared first-launch setup initially returned 69 but did not prevent the
shipping iOS CLI archive/export. Its latest check now succeeds with exit 0.
Preflight reports pending shared setup as a notice while retaining the device
archive/export gates. No license-acceptance command was run by the agent.

The restored team is selected in `project.yml`. Regeneration and Xcode's
capability refresh resolved the profile associations. Shipping Xcode archived
and exported build 79 successfully. Both final distribution profiles belong to
`PUH4GMFV56`, expire 2027-10-01, contain no device allowlist or enterprise grant,
and match their explicit App IDs. Strict app/extension code-signature
verification passed. Both signatures claim
`group.com.mesutcydev.ondevicemax.shared` and disable debugging. The main signature
claims the required memory/addressing capabilities and the exact
`iCloud.com.mesutcydev.ondevicemax` container with CloudKit in Production. Neither
signature claims PCC or debugging memory.

The verifier correctly handles Apple's profile authorization array for the
CloudKit environment and wildcard for services. Its actual-signature policy
still requires exactly CloudKit and Production. Twelve policy regression tests
passed, including rejection of Development signatures and unrelated services
despite broad profile grants. A profile is an allowlist rather than a copy of
the app's claimed entitlements.
[Apple provisioning profile guidance](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

The configured App Store Connect API key still fails authentication, but the
restored Xcode account can upload. After browser sign-in, the user-authorized
fresh record was created and verified: OnDevice Max, Apple ID `6818199563`,
exact bundle `com.mesutcydev.ondevicemax`, SKU `ondevicemax-ios`, English (U.S.),
iOS, limited user access. Existing unrelated listings were not changed.

Xcode reported build 79's upload successful and processing. It had completed
before the cancellation check for the later version/build request. The source
and share extension now use version 1.0, build 1; citation/SBOM/changelog records
were aligned without rewriting historical releases. The replacement signed
archive and export passed; the app and extension both verify as 1.0 (1).
Apple accepted its upload and Build Metadata now reports Validated. App Store
Connect reports version 1.0.0, build 1; the local signed app and extension both
specify version 1.0, build 1. It is assigned to the existing internal Me group
(two testers). The agent did not add testers or submit a build to Beta App
Review. The earlier build 79 remains in history and was observed Waiting for
Review; it was not altered by the agent. Agreements and production CloudKit schema/
sync behavior still need verification.

User-authorized disk cleanup removed obsolete generated archives, old IPA
outputs, and compile caches. Source packages, models, credentials, named
backups, build 78's archive, builds 76–78's IPAs, and QA/log evidence remain.
Fresh archives require 15 GiB. A cache with the verified matching shipping
SDK/toolchain uses a measured working-space budget with a 6 GiB floor. The
warm-cache preflight provided enough space for this successful archive/export.
An attempted `uv cache clean` timed out waiting on other users and was not
forced.

Automatic export may use cloud-managed distribution signing even without a
local distribution identity. The script reports a missing local identity as a
notice while retaining mandatory final team/profile/signature checks.
[Apple cloud signing](https://developer.apple.com/videos/play/wwdc2021/10204/).

Upload and processing are complete for the requested build 1. Required public
release checks: validate the production CloudKit schema and sync behavior.
PCC remains omitted; offering it additionally requires its managed capability
grant and separate runtime verification.
[PCC eligibility and access](https://developer.apple.com/private-cloud-compute/).

### Production functionality has not passed the device gate

**Missing acceptance evidence.** CoreAI cannot run in this project's simulator
build. Production compiled for generic iOS, but no full inference, thermal,
memory, camera, microphone, background cleanup, interrupted download, CloudKit
production sync, or signed share handoff was exercised on a physical iPhone in
this audit. The image catalog itself warns that SSD-1B's asymmetric loader
configuration needs device verification. Edge/developer mode exposes tight
models and must be included in memory and thermal testing.

Required resolution: test a clean install of the distribution candidate on
supported hardware, online and offline, with permissions denied and granted,
storage/memory pressure, cancellation, and foreground/background transitions.
Exercise network features on an IPv6-only network. Remove advertised models
that cannot reliably load and generate. Compile against shipping SDKs and run
Apple's final archive validation. Rules 2.1 and 2.4 are relevant.
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

### A Mac Catalyst release needs separate validation

**Conditional blocker for Mac distribution.** `project.yml` supports Catalyst,
but this audit built only iOS. `LegalAcceptanceManager` now bypasses mandatory
launch-document acceptance for Catalyst to address 2.4.5(vi); the documents
remain in Settings. Separately validate that behavior and audit the sandbox,
camera/microphone permissions, native framework slices, signing, CloudKit, and
runtime behavior. Do not infer Mac readiness from the iOS compile.
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## Other reviewed areas and their limits

| Area | Source observation | Verification still needed |
| --- | --- | --- |
| Ratings | No external App Store review SDK or custom review request remains. Model Arena's per-device Elo scores and answer-quality classifiers are model tools; they do not send App Store ratings. | Final signed binary and future changes. |
| Ads, tracking, payments | No advertising/tracking SDK, ATT flow, external checkout, subscription, or paywall was identified in the inspected app configuration/source. | Dependency privacy report and live listing; any future monetization needs a new review. |
| Public API use | CoreAI is documented by Apple. No dynamic private-API lookup pattern was found in the focused source search; extension-safe compilation passed. | Shipping SDK compile, final linked-symbol and archive checks. [Apple CoreAI](https://developer.apple.com/core-ai/). |
| Model downloads | The inspected paths download data consumed by embedded native runtimes. No downloader for executable iOS plug-ins was identified. | Explain download sizes, consent, models, optional features, and any external Mac companion in Review Notes. |
| Permissions and recording | Purpose strings exist for camera, microphone, speech, photos, saving images, and local network. Camera visibility follows the workbench lifecycle; inspected speech recognition requests enforce on-device operation. | Actual grant/denial, microphone indicators, foreground/background behavior, and saved media on hardware. |
| Local API and Mac bridge | API is opt-in and bearer-authenticated; pairing and risk approval boundaries remain. Foreground-only cleanup exists. | Network security testing, permission behavior, and companion setup documentation. |
| Accounts | No mandatory app-owned account/signup service was identified; an optional Hugging Face token is an external credential. | Listing and any later account features. |
| Privacy logs | The focused source search found no direct logging call printing prompts or credentials. | Runtime log capture, crash handling, and dependency behavior; a text search is not exhaustive evidence. |
| Icons | The source 1024 PNG has an alpha channel, while the inspected compiled iPhone icon is opaque. This is not a confirmed final-icon rejection. | Validate the final marketing icon and all alternate icons during export. |
| Store metadata | Bundle/version naming was checked locally. | Correct app/listing identity, accurate screenshots, support/contact links, privacy, age rating, export-compliance answers, pricing/territories, and reviewer setup. Check duplication concerns if another substantially similar app is listed. |

## Verification performed

| Check | Result and scope |
| --- | --- |
| Production Release `build-for-testing`, generic iOS, signing disabled | Passed after final source changes and again with shipping Xcode 27A266a for candidate 79 after installing the matching Metal toolchain. Compiled app and tests; did not execute device tests or produce a signed archive. |
| Compiled bundle resource verifier | Passed. Includes app and extension manifests, matching versions, native frameworks, dependency notices, and exclusion of the FastVLM encoder asset. Does not certify license eligibility or previously installed weights. |
| Shipping FoundationModels symbol check | Passed: all 170 imported symbols exist in the shipping SDK stub; none of the checked deprecated/renamed declarations are imported. This is a linkage check, not device behavior validation. |
| Repository validator | Passed after changes. |
| Distribution-profile policy tests | Twelve Python tests passed, including CloudKit profile allowlists/wildcards, expired/development/ad-hoc/enterprise/team/capability rejection cases. The actual owner-team signed export also passed verification. |
| Share inbox contract tests | Three passed. Covers multiple queued shares, special characters, corruption, oversized entries, expiration, and invalid schemes. An initial cleanup expectation was corrected and the affected suite rerun successfully. |
| Share receipt UI tests | Two passed: success and failure at accessibility XXXL text. Screenshots inspected. These exercise production receipt code inside `QA/NativeUI`, not the complete signed extension handoff. |
| Parent controls contracts | Four passed, including the QA app's actual Keychain round trip, restart preservation, retry delay, wrong PIN, and unavailable/corrupt storage. Unsigned simulator Keychain access failed; the signed QA harness passed. |
| Public model policy | Three tests passed: research/legacy identity rejection, Lens migration, and frozen source-revision enforcement, including both actual bundled Turbo revisions and exclusion of unavailable SD 2.1/Qwen 3.5 4B sources. Public/research catalog checks passed. Public source inventory retains 27 text and six image repositories. |
| Parent controls UI | Three flows passed: restriction/unlock through production Image Studio, wrong PIN and allowed state, and accessibility-size setup with its action reachable by scrolling and tested by tapping. Screenshots inspected. A rerun exposed incomplete synthetic PIN typing; the harness now taps and verifies each digit, and all flows passed. The retained image draft/navigation regression also passed. These fixtures do not execute diffusion inference. |
| Local App Store preflight/archive | Shipping Xcode 27A266a archive and App Store export succeeded after profile associations and working-space preparation. Strict signed app/extension verification passed. After exact app-record creation, build 79 uploaded successfully for processing. The requested 1.0 (1) replacement passed signed verification, uploaded, and finished processing as Validated. Apple labels the version 1.0.0; the local signed binaries specify 1.0. It belongs to the internal Me group. |

Logs and screenshot attachments are under ignored `build/appstore-*` paths.
Final beta production compilation passed in `appstore-compliance-final-compile-5.log`;
an earlier final attempt stopped on a full build database. Its integrity check
passed, generated caches were cleared, and the retry passed. Final PIN/policy/UI
evidence is in `appstore-compliance-final-ui-3.xcresult`,
`appstore-compliance-final-policy.xcresult`, and
`appstore-compliance-large-text.xcresult`.
Shipping production compilation passed in
`testflight-shipping-compile-79-2.log`, and the candidate's resource verifier
passed in `testflight-shipping-bundle-79.log`. The first shipping attempt failed
because the matching Metal toolchain was missing; installing the official
27A266a component resolved those compile errors. Shipping Xcode warns that the
installed CoreSimulator system framework was older; the latest first-launch
status now passes. The earlier simulator QA evidence remains from the beta
harness rather than the production device runtime. The Mac was unlocked after a temporary lock interrupted UI
work. Browser sign-in and exact app-record creation subsequently succeeded.
No license-acceptance command was run by the agent.

The successful signed artifact is
`build/appstore/1.0.0-79/export/OnDeviceMax.ipa`. That directory preserves the
archive/export logs, `signed-verification.log`, non-secret entitlement/profile
summary `signed-verification.json`, and `sha256.txt`. Initial prerequisite
failures are preserved in `upload-missing-record*.log`; the successful build 79
upload is recorded in `upload.log`. Its SHA-256 is
`00e679120071e6ae093d004f2a3cfaf152a6190445fcb44ae5a2226ac0f5d638`.

The beta simulator logged invalid-frame warnings while keyboards appeared;
focused flows and captured screens passed, but the shipping runtime still needs
verification. Existing dependency/compiler warnings are also not a warning-free
or concurrency certification. The new PIN-view default-argument isolation
warnings were corrected.
The new `build_appstore.sh` and `verify_appstore.py` prepare and check local
exports only. Their technical checks do not automate the licensing, safety,
privacy, metadata, and hardware decisions above. Follow
[Release verification](RELEASE_VERIFICATION.md) after those findings are closed.

The requested 1.0 (1) artifact and upload evidence are under
`build/appstore/1.0-1/`. The signed IPA SHA-256 is
`fc52130ef302dce695f1cc0e1bd6062b26f82227a8508a695a976f4ca8ae023d`.
Its exported app/extension versions, profile summary, strict signature result,
and successful official Xcode upload are saved in `signed-verification.json`,
`signed-verification.log`, `sha256.txt`, and `upload.log`.

Final portal evidence is saved as `testflight-status.json` and
`testflight-validated.jpg` in `build/appstore/1.0-1/`. Apple's Build Metadata
confirms Validated, build 1, SDK 24A430, exact bundle ID, both owner-team
entitlement sets, Production CloudKit, and debugging disabled. This establishes
technical upload/processing success and internal testing availability; it does
not close the public App Store compliance findings above.
