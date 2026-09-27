# Validation

## Integration validation — 19 September 2026

The package demo and the real OnDeviceMax target have now been compiled with Xcode 27. Native simulator interaction tests and screenshots were also captured. See the host repository's [integration record](../../../Docs/NATIVE_UI_IMPLEMENTATION.md) for results, fixture limitations and remaining physical-device checks. The original delivery status below describes the upstream package environment, not this integration run.

## Original delivery status and limits

This environment does not provide Apple SDKs, Xcode or an iOS simulator. The package has **not** been compiled, launched or rendered with Apple tooling here.

Available checks are limited to Swift grammar parsing, project/resource structure and source inspection. See `StaticValidation.json` for the captured results in the delivered package. Grammar acceptance is not Swift type checking, and a valid project file is not a successful build. Generated UI mockups are not runtime screenshots.

## Build on a Mac

From the folder containing `Package.swift`, run:

```bash
bash Scripts/verify-on-mac.sh
```

The script requires Xcode 26+ and an iOS 26+ Simulator SDK. It runs this equivalent build:

```bash
xcodebuild \
  -project Example/OnDeviceUIDemo.xcodeproj \
  -scheme OnDeviceUIDemo \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/Validation/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The script captures `.build/Validation/build.log`. A generic simulator build does not launch the app. Open the example in Xcode, select an installed simulator and run it. Build the actual production target separately after integration.

## Visual and interaction checks

| Check | Acceptance |
| --- | --- |
| Native shell | One real system tab bar, no custom replacement or root tint override; normal conversation-title header; no overlapping composer or sheet |
| Composer geometry | One rounded content surface; writing area above footer; attachments inside; LayoutMetrics governs app content; field grows through six lines; Return inserts a newline |
| Header and footer controls | Active model picker centered in the chat navigation bar; plain plus on the footer left; separate supported microphone and Send on the right; Send stays visible but disabled when empty/unavailable and becomes supported Stop while responding |
| Attachment strip | Inside the composer above the writing area; stable name/kind shown; remove is capability-gated; sending snapshots IDs |
| Draft ownership | Failed or rejected sending preserves the draft; accepted clearing never erases newer or another conversation’s input |
| Transcript | User bubble cap and text insets scale correctly; assistant remains readable; manually reading older output is not pulled down by a stream |
| Image studio | Result caption remains tied to its generating prompt while Next image changes; missing model gives an actionable path; unsupported Create stays disabled |
| Settings | Native grouped list; native Appearance menu; no decorative thumbnails |
| Voice | Preview/selection are separate, input/output controls independent, no preview over an active session, minimize and end follow accepted host state |
| Lens | Permission/unavailable states remain legible; supplied camera and capture lifecycle stay host-owned |
| Model and Device | Selected/installed/loaded states differ; unavailable measurements are explicit; no simulated readiness or numerical progress |

Run these on a compact and large iPhone, light and dark appearance, keyboard open and closed, larger accessibility text, Reduce Motion, Reduce Transparency and VoiceOver. Inspect content under native glass after scrolling; verify contrast in the actual rendered composition.

Use the example’s **Preview controls** for New chat, example conversation, attached draft, static model states, visual voice states and **Show image result**. These fixtures test presentation only. The example does not run inference, download a model, start recording, capture an image or process `notes.txt`.

In the integrated app, additionally test one real text submission, supported attachment submission/removal, model preparation failure, actual camera/microphone permission denial, image completion and voice resumption. Use the existing meaningful test suite for affected services; do not replace its checks with snapshot comparisons to generated mockups.

## Completion record

Record Xcode/SDK and simulator or device versions, build result, exercised states and any remaining issue. Attach actual screenshots for the final composer, native tabs, image-result draft separation, dark appearance and large text. State explicitly when a scenario could not be run.
