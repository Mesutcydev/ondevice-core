# TestFlight build 9: downloads, MiniCPM Assistant and Lens waiting

OnDevice: Max **1.0.1 (9)** is processed **VALID** and available for internal
TestFlight testing (**IN_BETA_TESTING**). Apple records the upload at
**October 14, 2026, 00:03:04 Europe/Istanbul**. Build ID is
`3168b4a3-fab0-469b-a9fe-06690b141afc`, app `6818199563`, bundle
`com.mesutcydev.ondevicemax`. The existing internal **Me** group has access to
all builds. English What to Test notes were published and read back. The external
state is `READY_FOR_BETA_SUBMISSION`.

## Changes

Lens now shows the actual inference step, an elapsed timer, a spinner and a
44-point Stop button. The sequence is **Preparing model → Reading image →
Preparing answer → Writing answer**. The MiniCPM 35B engine emits the image,
prefill and decode events. A short explanation tells users why a large local
model takes longer. The layout supports accessibility text sizes. Stop cancels
an active load or generation, drains native work, and prevents late callbacks
from changing a cancelled result. The UI presents elapsed time without an
estimated completion time or a synthetic percentage.

The downloaded MiniCPM 35B model now appears in the Assistant picker and runs
text through its isolated expert-streaming engine. Both curated MiniCPM entries
declare text and vision roles. The existing memory, thermal, context,
cancellation and runtime ownership policies apply to this path. The model stays
experimental and requires a 12 GB class device, at least 4.8 GB available model
memory and approximately 35 GB free storage for download and preparation.
The pinned source files and preparation contract are unchanged, so an existing
completed build-8 download can be reused. See the
[model support audit](MINICPM_V47_SUPPORT_AUDIT_2026-10-13.md) for exact revisions,
checksums, licenses and runtime limits.

Interrupted Edge0 35B preview downloads expose Cancel and Resume. Cancellation
removes durable ownership, cancels and drains writers, then cleans partial files
and resume receipts. A late delegate completion cannot recreate the cancelled
download. Variant ownership protects files shared with a sibling model. A
cancelled interrupted row stays gone after relaunch.

Public App Store downloads enqueue their complete file manifest in a persistent
background URL session. Restoration reconnects system tasks and recovers their
progress. Existing per-file integrity checks and installation still run before a
model becomes ready. Downloads have a dedicated WidgetKit extension for a black
Lock Screen card and Dynamic Island presentation: cyan progress ring, percentage,
model name, byte totals and download/preparation state. Tapping the activity
opens the app's Downloads screen. Pause, cancellation, failure and completion
end the activity; restored duplicate activities are also dismissed.

iOS schedules background transfers and can interrupt them after force quitting.
Model preparation and installation finish with the app open. These boundaries
follow Apple's [background download documentation](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
and [Live Activity guidance](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

## Verification

| Check | Result |
| --- | --- |
| Download scope, persistent journal and coordinator | 18 host tests passed, including restored tasks, late cancellation/pause callbacks and shared-folder variants |
| MiniCPM catalog, artifact integrity and execution policy | 16 host tests passed |
| App Store packaging and framework metadata rules | 32 tests passed |
| Production UI: interrupted cancellation/relaunch, both model detail/download routes, Lens waiting/Stop and large text, ActivityKit start/end | 6 simulator UI flows passed |
| Settled system Dynamic Island and activity cancellation | A further run passed; system screenshot visually inspected |
| Real 35B text and image inference | Arithmetic, sampler settings, token metrics, output cap, four image turns, cancellation/retry, reload and top-eight routing passed on Apple silicon Mac |
| Real Lens inference stages | Image encoding → prompt prefill → answer decode order passed |
| Production iPhone compile | Shipping Xcode Release `build-for-testing` passed for generic iOS with signing disabled |
| Catalog and links | Catalog invariants, all 36 existing model-pack probes and all six pinned MiniCPM file probes passed |
| Source hygiene and whitespace | Passed |

The simulator runs the production `OnDeviceUI` package through `QA/NativeUI`.
CoreAI requires a physical device, so the complete production app cannot run in
the simulator. Sustained iPhone inference performance, thermal behavior and a
long background transfer on hardware remain device acceptance checks. The Mac
checks do not establish iPhone speed or peak memory.

## Release packaging

The archive uses shipping Xcode **27A266a**. The app, share extension and new
download widget all report **1.0.1 (9)**. The embedded `ODMiniCPM` framework has
valid `CFBundleShortVersionString`, `CFBundleVersion` and `MinimumOSVersion`
values, and the verifier checks every embedded framework. All six private
MiniCPM functions are imported, and both native runtime UUIDs match the reviewed
device slices.

Automatic export attempted cloud signing and failed for the new widget. Export
then used the existing local Apple Distribution identity and explicit validated
profiles for all three bundles. The unchanged archive was reused. The signed
export passed profile, entitlement, resource, privacy manifest, framework
metadata and code-signature checks. All **1,081** fingerprinted source files
stayed unchanged; all **18** package checkouts matched their locked revisions.

IPA SHA-256:
`aefde480120df26c3838dce3b8d3b927ea5dde80787b91d7020ae548c2a31de2`.
The local checksum was verified before upload and after Apple processing.

Local evidence is retained in ignored `build/appstore/1.0.1-9/` and
`build/minicpm-release-2026-10-13/`, including `build-9-ui.xcresult`,
`build-9-activity-system.xcresult`, their logs and exported screenshot, the
signed IPA, source fingerprint and native runtime verification records.

[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).
