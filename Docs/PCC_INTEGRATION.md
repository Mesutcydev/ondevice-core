# Apple Private Cloud Compute (PCC) integration — IOSLocalLLM / "iOS Local LLM"

Status: **Runtime, dispatch, cancellation, context budgeting, picker/privacy
UX, quota state, reasoning selection, conversation restoration, and per-message
attribution are implemented. The build-entitlement gate (see §3a) is implemented
and verified on the simulator; physical-device validation of an entitled install
remains.**

PCC is presented as **"Apple Private Cloud"** — an *optional advanced reasoning
model*. It does **not** replace MLX, GGUF, downloaded HF models, local vision,
speech, TTS, embeddings, image gen, the lens pipeline, offline chat, or the
thermal/memory protections. The app stays local-first.

---

## 1. The SDK reality (verified against the installed SDKs on 2026-06-24)

`PrivateCloudComputeLanguageModel` and the reasoning/quota APIs exist **only in
the iOS 27 SDK** shipped with **Xcode 27 beta** (`/Applications/Xcode-beta.app`,
27.0 / build 27A5218g). The **currently-selected** toolchain is **GA Xcode 26.6**
(`/Applications/Xcode.app`), whose `FoundationModels` framework has **no** PCC
symbols. (The `~/Desktop/FM_ios.swiftinterface` dump was taken from the GA SDK and
is therefore missing PCC — don't trust it.)

Consequence: **`canImport(FoundationModels)` is `true` on both SDKs**, so it
cannot gate PCC. We gate on a dedicated build flag **`FM_PCC`** instead.

### Verified API surface (iOS 27, `arm64e-apple-ios.swiftinterface`)

```swift
@available(iOS 27.0, *) final class PrivateCloudComputeLanguageModel: Sendable, LanguageModel {
    init()
    var availability: Availability        // .available | .unavailable(.deviceNotEligible | .systemNotReady)
    var isAvailable: Bool
    var quotaUsage: QuotaUsage            // .status, .isLimitReached, .limitIncreaseSuggestion?, .resetDate?
    var contextSize: Int { get async throws }   // NOTE: async throws, not a plain Int
    enum Error { case networkFailure(_) , quotaLimitReached(_) , serviceUnavailable(_) }
}
struct QuotaUsage {
    enum Status { case belowLimit(BelowLimit /*.isApproachingLimit*/), limitReached(LimitReached) }
    struct LimitIncreaseSuggestion { func show() }   // the brief's "Show Options"
}
struct ContextOptions {                  // pass via respond/streamResponse(contextOptions:)
    enum ReasoningLevel { case light, moderate, deep, custom(String) }   // NO `.automatic`
    init(includeSchemaInPrompt: Bool? = nil, reasoningLevel: ReasoningLevel? = nil)
}
LanguageModelSession(model: some LanguageModel, tools: …, instructions: String?)
session.streamResponse(to: String, options:, contextOptions:, metadata:) -> ResponseStream<String>
// ResponseStream yields CUMULATIVE snapshots (Snapshot.content: String) — diff to deltas.
// `LanguageModelSession.GenerationError` is DEPRECATED in 27 → use `LanguageModelError`.
```

Differences from the original handoff brief: `contextSize` is `async throws`;
reasoning is `ContextOptions(includeSchemaInPrompt:reasoningLevel:)` passed to
`respond`/`streamResponse`, not a model-construction arg; `ReasoningLevel` has a
4th `.custom` case and **no `.automatic`** (automatic is an app concept).

---

## 2. Build strategy — compile-flag gated (chosen)

GA Xcode 26.6 stays the **default / shippable** toolchain; the GA build is
**byte-for-byte unaffected** because every PCC-touching line is behind `#if FM_PCC`.
The App Store will not accept beta-Xcode builds until iOS 27 is GA, so PCC can be
developed/tested now but ships later.

**To build the PCC-enabled variant:**

1. Select Xcode 27 beta:
   `sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer`
2. Build normally. `project.yml` automatically adds `FM_PCC` for
   `iphoneos27.*` / `iphonesimulator27.*`, and uses
   `IOSLocalLLM-PCC.entitlements` for iOS 27 device builds.
3. Build on a **physical iOS 27 device** with Apple Intelligence enabled. PCC does
   not run in the Simulator.

Revert to shipping: `sudo xcode-select -s /Applications/Xcode.app` and build.
The iOS 26 SDK does not match the conditional settings, so it uses the original
entitlements and local-only implementation.

Both paths are verified to type-check clean (zero warnings):
- GA SDK, no flag → `swiftc -typecheck -sdk iPhoneOS26.5` ✅
- iOS 27 SDK, `-D FM_PCC` → `swiftc -typecheck -sdk iPhoneOS27.0` ✅

---

## 3. Entitlement

PCC requires `com.apple.developer.private-cloud-compute`. The Developer
account already has access to it.

`IOSLocalLLM/IOSLocalLLM-PCC.entitlements` contains the capability and is selected
only for `iphoneos27.*`. The normal iOS 26 build and the Share Extension retain
their existing entitlement files. Automatic signing still needs to produce an
iOS 27 provisioning profile carrying the capability during physical-device
validation.

### 3a. The entitlement is a runtime requirement, not a build detail

The entitlement is **provisioning-managed**: an app that carries it only installs
on a device whose signing profile grants it. A sideloaded, re-signed IPA (the
track this project ships) is normally re-signed *without* it.

That combination used to crash the app, because
`PrivateCloudComputeLanguageModel` **traps with a fatalError** instead of
throwing when the process lacks the entitlement — while `availability` still
reports the model as usable:

```
FoundationModels/PrivateCloudComputeLanguageModel.swift:963:
Fatal error: Process is missing required entitlement:
com.apple.developer.private-cloud-compute
```

Reproduced on the iOS 27 simulator against this app's own facade
(`build/pcc-repro-sim.log`, crash report `OnDeviceCoreAIStudio-2026-09-18-185447.ips`):
`currentStatus()` answered **`.ready`**, `contextSize()` answered **32768**, and
the SIGTRAP fired on the first generation attempt. The framework's own answer
therefore cannot be used as the gate — nothing may touch the PCC model, not even
to read `availability`, until the process is known to carry the entitlement.

The gate is `EntitlementsProbe` (`IOSLocalLLM/Services/EntitlementsProbe.swift`),
and it is deliberately **two-part**, because the signature alone is not the whole
contract:

1. the running executable's own code signature must carry
   `com.apple.developer.private-cloud-compute` (read from the `CS_ENTITLEMENTS`
   blob — read-only, no private API, any failure means "not entitled");
2. when the bundle also ships a provisioning profile, that profile must *grant*
   the capability. A re-signer can keep an app's entitlement blob while signing
   with a profile that does not grant it, and the system then refuses the
   capability at runtime with the same fatal message. Installations with no
   profile (plain ad-hoc sideloads) have no profile contract, so the signature is
   the whole story there.

`EntitlementsProbe.isGranted(signatureEntitled:hasEmbeddedProfile:profileEntitled:)`
is the pure rule behind that, tested for every combination.

Consequences in the app:

- `ApplePrivateCloud.isProvisionedForCurrentBuild` is the build gate, distinct
  from `isSupportedOnCurrentOS` (SDK + OS) and `isCompiledIn` (FM_PCC).
- `ApplePrivateCloudRuntime`'s model handle is **`nil`** unless the entitlement
  is present, and every method refuses (`.entitlementUnavailable`,
  `ApplePCCError.notProvisioned`) without reaching FoundationModels.
- The picker shows the row with "Not enabled for this build" and an explanation
  instead of a status read from the framework; choosing it raises a toast naming
  the entitlement, and "Set as default" is disabled.
- `CodingAssistantService.selectApplePrivateCloud` refuses the switch and
  repairs a stale persisted PCC default back to the device-tier model, so a
  build without the entitlement never strands new conversations on a model that
  can only refuse.
- Status refresh, generation, cancellation and "Show Options" all check the gate
  first; refusal is breadcrumbed (`pcc generation refused · missing Private
  Cloud Compute entitlement`).

A build signed for a profile that grants the entitlement behaves exactly as
before: the probe returns true and the path is unchanged.

---

## 4. What's implemented this session

| File | Gate | Purpose |
|---|---|---|
| `IOSLocalLLM/Services/EntitlementsProbe.swift` | always compiled | Reads this binary's own code signature for `com.apple.developer.private-cloud-compute`. The gate that keeps an unentitled process away from a framework that traps. |
| `IOSLocalLLM/Models/ApplePrivateCloudTypes.swift` | always compiled | `ModelExecutionLocation`, `ApplePCCStatus`, `ApplePCCReasoningLevel`, `ApplePrivateCloud` identity, `ApplePCCRequest`, `ApplePCCError`. No FoundationModels import. |
| `IOSLocalLLM/Models/ApplePrivateCloudPromptBuilder.swift` | always compiled | Separates system instructions from ordered dialog, preserves hidden grounding, and omits empty streaming placeholders. |
| `IOSLocalLLM/Services/ApplePrivateCloudRuntime.swift` | facade always / actor `#if FM_PCC` | `actor ApplePrivateCloudRuntime` (availability, quota→status, `contextSize`, session, **delta** streaming, per-request cancellation, error mapping). `ApplePrivateCloud.{currentStatus,contextSize,stream,answer,cancel,showLimitIncreaseOptions}` facade — returns `.unsupportedOS` / throws cleanly on GA. |
| `IOSLocalLLM/Services/CodingAssistantService.swift` | always compiled | Separate cloud execution/generation state, dispatch, real context budgeting, cancellation/drain, and explicit no-silent-fallback errors. |
| `IOSLocalLLM/Views/AssistantModelPickerView.swift` | runtime gated | Separate cloud section, availability/quota UI, reasoning level, and versioned privacy disclosure. |
| `IOSLocalLLM/Models/ChatMessage.swift` / `ConversationStore.swift` | always compiled | Optional model/execution attribution that remains backward-decodable. |

Design choices honoring the brief:
- PCC is **not** forced into `AssistantModel`/`DownloadableModel`/HF structures (no
  file URL, repo, size, quant, unload). Execution location is a **pure classifier**
  (`ModelExecutionLocation.of(assistantModelID:)`) over the id — no new persisted
  field, so the `Codable` records that embed `AssistantModel` need no migration.
- Streaming yields **deltas** (diffed from cumulative snapshots) to match the app's
  existing `onToken: (String) -> Void` append contract.
- Cancellation is per-request (`cancel(requestID:)` + stream `onTermination`); it
  touches **no** local-model unload / MLX / RAM paths.
- Hidden reasoning (`Transcript.Entry.reasoning`) is never surfaced or persisted.
- Errors map to a small user-facing set and never echo prompt/attachment text.

---

## 5. Remaining validation

- Confirm automatic signing creates a profile containing the PCC entitlement.
- **PCC can only be exercised end-to-end on an install whose signing profile
  grants `com.apple.developer.private-cloud-compute`.** On any other install the
  app now reports "Not enabled for this build" and never reaches the framework —
  that state is verified (simulator, build 56); the entitled state is not.
- Exercise ready, approaching-limit, limit-reached, offline, cancellation, and
  model-switch paths on a physical iOS 27 device.
- Verify the system-provided quota-increase UI.
- Re-run the full unit/UI suite with the final Xcode 27 GM before shipping.
