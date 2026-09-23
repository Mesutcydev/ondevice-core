# API server workspace

The leading sidebar now opens **API server** as a retained primary workspace.
It does not present the former Mac pairing sheet. Device’s Advanced tools entry
opens the same workspace. Mac pairing and the chat-menu bridge probe are hidden;
the underlying pairing implementation and stored credentials are preserved.
Legacy bridge navigation requests redirect to the API workspace.

`LocalAPIServerView` uses the existing `LocalAPIManager`, `AppSettings` and
`CodingAssistantService`. Opening the page only refreshes local addresses. The
user must explicitly enable the listener. Enable/stop, restart, port validation,
keep-awake preference, downloaded model selection/loading, URL copy, API-key
reveal/copy/rotation and setup-command copy remain connected to these services.
The model picker is a contextual sheet; the server workspace itself is not.
Authentication, port limits, model residency, thermal/memory gates and background
shutdown remain in the existing services without changes.

The primary route uses the same host lifecycle compatibility mapping as Device
and Image studio. Visited views stay mounted, preserving unsaved port edits.
The API navigation bar hides when its workspace is inactive so UIKit does not
leave a stale menu button in the accessibility tree.

## Verification scope

`QA/NativeUI` compiles the actual production server view with explicit review
service fixtures. These never open network sockets or use production API keys.
`APIServerWorkspaceTests` exercises routing, absence of a workspace sheet,
draft retention, invalid ports, enable/stop/restart, model selection, connection
and key controls, and light/dark/accessibility text layouts.

Existing sidebar host-camera lifecycle and chat draft/attachment scenarios pass
in `build/api-workspace-tests-final.log`. That log also retains failed initial
switch interaction attempts: XCTest tapped the row label rather than the native
switch. Final API-control results and release evidence are recorded below after
verification. A simulator pass does not prove a physical-device HTTP request.

## Final UI verification

All three API workspace tests passed in `build/api-workspace-verified.log`:
light/dark/accessibility layout and port validation; navigation/draft retention,
start/stop/restart and model picker; URL/key/setup controls. The three existing
route/voice-setup, chat-draft and camera-selection regressions passed in
`build/api-workspace-tests-final.log`. Repository hygiene passed in
`build/api-repository-validation-final.log`.

Final screenshots are in `build/native-ui-evidence/api-server/`. Native switch
and port tests target the actual trailing controls. The model picker’s sheet is
owned by the page root, since attaching presentation to a Form Section did not
present reliably. These implementation issues were fixed before release.

## Build 44

- IPA: `build/releases/OnDeviceMax-sideload-entitled-1.0.0-44.ipa`
- Size: 46,168,235 bytes.
- SHA-256: `7656ecacca4b8ad108e4a8456d544d3065baf7f54bfaa89848fb423dcb68b23e`.
- Release script completed all eight stages: `build/api-release-44.log`.
- Independent verification: `build/releases/OnDeviceMax-44-verification.json`.
  Payload structure and exact full app/share-extension entitlement dictionaries
  match. All 328 frozen source/configuration fingerprints remained unchanged
  through the archive.
- The profile-less IPA requires installer-side re-signing. No build 44 physical
  device installation or end-to-end HTTP request is claimed.
- iCloud copy: `OnDevice Builds/OnDeviceMax-sideload-entitled-1.0.0-44.ipa`.
  Foundation confirmed uploaded=true, uploading=false, upload error=nil; copied
  file SHA-256 matches the verified IPA. The initial transient iCloud 4355 error
  cleared on the follow-up check.
