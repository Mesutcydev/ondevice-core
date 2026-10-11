# App Store compliance fixes — 2026-10-08

This records the follow-up to the read-only audit. The owner authorized fixes,
with existing app functionality preserved. No version was submitted or released.
Earlier local changes remain in the working tree.

## Implemented

1. **Review manipulation:** retained the existing removal of the custom
   sentiment-gated review funnel. The release verifier now rejects its known
   markers even if someone restores it under a different filename. Apple's
   native review API remains permitted; ordinary support reporting is separate
   from App Store ratings.
2. **Age assurance:** corrected the live declaration for app `6818199563` from
   `true` to `false` using Apple's public App Store Connect API. Verified the
   saved response. Parental controls and the other questionnaire answers were
   preserved. The parent PIN is not an age-verification mechanism.
3. **Privacy/support:** replaced the obsolete in-app GitHub privacy link with
   `https://ondevice.fun/privacy/` and aligned support with
   `https://ondevice.fun/support/`. Removed blanket local-only inference and
   network claims from the embedded disclaimer and device notice. Legal text
   version is now 6, dated October 8, 2026. The local policy also clarifies
   opt-in private CloudKit records, provider accounts and information deliberately
   posted for support, rather than claiming the project can never see any data.
4. **Model attribution:** added a prominent “Built with Llama” label in Legal →
   Attributions, Meta copyright notices beside the bundled 3.1/3.2 agreements,
   and release checks for those notices in both source and app bundles. Added
   Liquid AI and Stability AI entries, including their custom-license conditions.
5. **Content safeguards:** added app-owned chat safety instructions through the
   shared generation entry point, covering chat, voice and local API callers.
   The policy retains caller formatting instructions and conversation history,
   produces one leading system message, and is idempotent on retries. Image
   generation checks explicit-content phrases before loading/downloading and
   adds exclusions to the negative prompt. UI and tool requests use the same
   image service. This introduces no model, dependency, entitlement or remote
   moderation request and preserves existing residency/cancellation paths.
6. **Reporting/removal:** chat response and image action menus provide a content
   concern sheet. It opens the existing support website only when selected and
   attaches no user content or diagnostics. Image deletion uses a native alert
   with explicit Cancel and Delete actions, removes the current app-owned cache
   result, and retains downloaded models and externally exported copies.
   Reporting is unrelated to rating prompts.

## Limits that remain release conditions

- **Generated-content safety is not fully closed.** Phrase checks and system
  instructions are precautions, not a validated semantic or image-output
  classifier. They can miss obfuscated requests, other languages, prompt
  injection, and objectionable pixels produced from otherwise ordinary prompts.
  Turbo presets may ignore negative prompts. Do not describe this as comprehensive
  moderation or use it to justify every age-rating category being `NONE`.
  A public candidate needs physical-device/adversarial validation and, where
  required, effective output moderation. Image Studio remains available; no
  feature was silently removed to make the audit appear resolved.
- **Commercial rights:** the publisher confirmed revenue below the relevant
  LFM and Stability community-license thresholds. The checked LFM v1.0 text has
  no registration prerequisite. Stability commercial registration or a separate
  license still requires owner evidence. No contract was accepted on the owner's
  behalf. Other model-specific acceptable-use and redistribution conditions
  remain applicable. Sources: [LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct/blob/main/LICENSE)
  and the [pinned Turbo Community License](https://huggingface.co/stabilityai/sd-turbo/blob/b261bac6fd2cf515557d5d0707481eafa0485ec2/LICENSE.md).
- **Privacy publication:** existing approved answers declare linked Search
  History (functionality/other purposes), User ID and Other Data Types
  (functionality), with no tracking. Confirm publication in Apple's App Privacy
  interface and complete its accuracy attestation. The normal web interface
  currently requires owner sign-in. No unofficial privacy endpoint was used.
  Source inspection confirms opt-in sync uses `CKContainer.privateCloudDatabase`,
  storing the conversation JSON, including any persisted presentation/drafts.
  Apple says private-database data is unavailable in the developer portal and
  excludes Apple-collected data from the developer's disclosure responsibility.
  Our interpretation is that this private sync alone does not establish a
  missing publisher-collected User Content category; provider-retained web
  queries and identifiers still need disclosure. This does not describe sync
  as on-device processing. Sources: [privateCloudDatabase](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase?changes=_9)
  and [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).
- **Hardware and classification:** there is no available connected physical
  iPhone. CoreAI inference, real model downloads, image output, camera/voice,
  memory/thermal behavior and CloudKit cannot be certified by the UI fixtures.
  Apple determines any applicability of guideline 4.7 to downloaded AI models;
  the app does not download executable app code or provide person-to-person
  messaging/public UGC merely by generating local responses.
- **Build identity:** preserved build 81 predates these changes. It must not be
  represented as containing these fixes. The new unsigned compile uses the
  existing source version/build metadata, 1.0 (81), solely for validation.
  The owner subsequently requested a new upload: a fresh signed 1.0 (82)
  export passed verification and was uploaded successfully (details below).
  Do not reuse an old IPA as proof of the new code.

## Validation

- After the owner authorized disk cleanup, removed inactive compiler
  intermediates, indexes and precompiled module caches. Source, package
  checkouts, model files, release archives and test evidence were retained.
  Free space increased from roughly 684 MiB to 16.87 GiB before the new build.
  The target manifests and deletion results are saved in the ignored evidence
  directory. Active build caches were excluded. After validation, removed only
  the two simulators created for this audit and completed voice-test scratch
  products, retaining their logs/results/screenshots. No pre-existing simulator
  was erased. Final observed free space was approximately 11 GiB; the new
  production bundle and incremental compile cache remain available.
- 24 Python distribution-policy tests pass, including retired review-funnel
  rejection, native review allowance and missing Llama-notice rejection.
- Source distribution checks and repository validation pass.
- All 25 `VoiceAgentOrb` package tests pass.
- Current simulator policy contracts: **8 passed** (5 content-policy tests and
  3 public-model-policy tests). The shared chat-policy test checks history,
  caller formatting, one leading system message and retry idempotence. The
  same 5 content-policy tests also passed in an isolated macOS Swift package
  using copies of the production Foundation sources. These tests verify the
  helpers, not iPhone inference.
- Final focused UI regression: **8 passed, 0 failures** on a dedicated iPhone
  18 Pro simulator, using the production SwiftUI files through `QA/NativeUI`.
  This covers chat/image reporting and dismissal, image deletion Cancel and
  confirmation, retained model availability, image draft/navigation and
  original-prompt retention, parent-PIN restrictions, wrong-PIN rejection and
  large-text setup. Evidence: `final-ui.xcresult` and the associated log.
- Independent device-interaction verification also passed: the alert visibly
  contained Cancel, Delete image and the exported-copy explanation. Cancel
  dismissed it and preserved the displayed image and model controls. Four
  screenshots and the verification report are saved under
  `independent-image-verification/`. This verification used a UI fixture.
- Earlier failed runs remain in the evidence directory. The deletion attachment
  showed an adaptive confirmation popover without a visible Cancel action;
  replacing it with an alert fixed the issue and passed a focused deletion run
  before the final suite. The reporting test compares the draft actually
  delivered before opening the sheet, and the chat-menu test waits for its row.
  A separate small-device run failed keyboard accessibility interactions; the
  final dedicated modern simulator passed the parent-control tests without
  changing their implementation. The beta simulator runtime still reports
  duplicate accessibility classes and invalid frame-dimension warnings. These
  passes do not certify every device size or eliminate those runtime warnings.
- **Production compile gate passed:** unsigned Release `build-for-testing`
  for generic iOS using shipping Xcode 27.0 (`27A266a`), the public model policy
  and an isolated package cache. The actual app, share extension and production
  test targets compiled/linked successfully. This does not execute device tests
  or verify an App Store distribution signature. Evidence:
  `build/compliance-fixes-2026-10-08-production-final.log`.
- The newly built app passed `verify_appstore.py --source --app` resource
  validation with expected version 1.0, build 81 and toolchain `27A266a`.
  This includes both privacy manifests, model-revision inventory, required
  license texts/notices, app/extension metadata, native frameworks and exclusion
  of research-only bundled artifacts. No signed-distribution result is claimed.
- Build warnings remain for existing architecture/thinking cache actor
  isolation, an unnecessary `await`, and optional bundled Lens model absence.
  No model weights were added. The absent Lens artifact requires the existing
  explicit download flow, which still needs device validation.
- Public privacy and support pages returned HTTP 200. The published privacy
  page is dated October 2, 2026 and describes the optional network features,
  private CloudKit, provider retention, public support issues and site hosting.
  Local October 8 additions describe the new safeguards/reporting; website
  publication of those additions was not performed. Public HTML/text snapshots
  are retained as evidence.

## Next validation steps

1. Validate real model behavior and content bypasses on a physical iPhone,
   then reconcile the age-rating frequencies with observed functionality.
2. Resolve Stability registration evidence and sign into the normal App
   Privacy interface to verify/publish the approved declarations and attest
   accuracy. Do not submit a version until these release conditions are closed.
3. Publish the reviewed policy additions and complete signed-device acceptance
   before treating uploaded build 82 as ready for public App Review.

## Subsequent owner-requested build upload

- Confirmed the exact existing app, `6818199563`, bundle
  `com.mesutcydev.ondevicemax`. Build 81 was the newest uploaded build; selected
  unused build 82 for both app and extension in `project.yml`, then regenerated.
- Shipping Xcode `27A266a` archived and exported version **1.0 (82)** with owner
  team `PUH4GMFV56`. Resource checks, FoundationModels symbol verification,
  strict app/extension distribution signatures, profiles and entitlements passed.
  Compliance-source hashes were unchanged during the archive.
- Uploaded the verified IPA through the official App Store Connect upload API.
  A fresh build query confirms **`VALID`**, build ID
  `5fe46b46-0994-46c4-8d84-3b08130ec995`, uploaded October 8, 2026 at 22:17:57
  Europe/Istanbul. Local IPA SHA-256 was verified before upload; the API
  supplied no server checksums. No public App Review submission was performed.
- Archive, export, checksum, upload result and final processing evidence are
  retained in the ignored `build/appstore/1.0-82/` directory. The earlier
  licensing, privacy and physical-device/content-safety conditions still apply.

Evidence is in the ignored `build/compliance-fixes-2026-10-08/` directory and
associated logs. Failed results remain recorded alongside successful checks.
