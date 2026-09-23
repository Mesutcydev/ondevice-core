# Lens camera startup regression — build 39

## Cause and change

The native tab bar writes `ODBridge.store.selectedTab`. `ContentView` observed
`ODBridge`, but that adapter does not forward its nested `ODStore` publisher.
Its `onChange(of: odBridge.store.selectedTab)` could therefore miss navigation:
Lens appeared while the host remained on its previous tab, so camera setup and
start never ran. An unrelated host refresh could hide the failure intermittently.

`WorkbenchSelectionObserver` now subscribes directly to the selection publishers.
It delivers the initial tab and subsequent distinct selections to the existing
host tab state. Camera setup, tab-leave stop, voice cleanup and coordinated model
residency still run through the existing `ContentView` lifecycle rules.

Lens mode had the same nested-observation problem. It now reaches the existing
preset/cancellation handler directly, without resetting the saved prompt or
result on initial subscription. Unrelated streaming updates do not retrigger
either selection handler.

No camera capture, preview rendering, inference, thermal policy, model-loading,
signing identity or entitlement implementation was changed for this fix.

## Regression evidence

- Two hosted SwiftUI tests first ran with the previous `onChange` observation
  behavior. Both failed: Lens entry/exit/return, initial Lens selection and mode
  changes never reached the host callback (`build/lens-selection-red.log`).
- With the publisher subscriptions, both tests pass. All seven existing host
  contract tests also pass (`build/lens-selection-green.log`).
- Three native UI tests pass (`build/lens-ui-regression.log`): actual native tab
  taps through Chat → Lens → Voice → Lens → Chat → Models reach the production
  observer; denied camera access still exposes Settings; Stop still cancels
  Lens analysis. The latter two use existing isolated service fixtures.
- Repository validator and whitespace checks pass. The original app and share
  extension entitlement files and `Podfile.lock` retain their input checksums.

These tests establish the lifecycle wiring fix, not a physical camera-feed
test. The user's iPhone 17 Pro Max was unavailable to CoreDevice during this
run. The production app imports device-only CoreAI and cannot run in Simulator.

## Device acceptance

Install build 39 using the existing re-signing workflow. Cold launch, enter
Lens, allow camera access if asked, and verify the preview and a real capture.
Then switch to Chat and back, background/foreground on Lens, and verify capture
again. Build 38 remains available in the shared folder for comparison.

## Build 39 delivery

The complete device Release archive and sideload package passed the repository
release verifier and an independent extraction/signature/entitlement check.
The package is in the existing shared OnDevice Builds folder. See
[the screenshot audit](DEVICE_SCREENSHOT_POLISH_2026-09-19.md) for the release
hash, UI checks and remaining real-device acceptance steps.
