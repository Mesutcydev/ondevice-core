# Conversation home and sidebar — 19 September 2026

The user's latest screenshots explicitly replace the prior tab-bar direction.
The home page is a plain pinned/recent conversation list, with native search,
Voice and New chat controls at the bottom. A leading sidebar pushes the main
page aside and contains Library, Current chat (after first opening one),
Lens, Voice, Image studio, Models, Device, Mac bridge, search and history.
The home also lists these real workspaces below history so a small chat library
retains useful destinations instead of a large empty hero area.
Chat and Settings remain anchored at its foot. No invented project/plugin
features are copied from the reference.

## Wiring and state

- Conversation rows dispatch the existing AppBridge open-conversation path.
  Selecting the current conversation resumes its mounted view without reloading.
- New chat dispatches the existing pending-new-chat path, including cold entry.
- Search filters the real title and recent-message preview, in both home/sidebar.
- Pin/unpin persists optional metadata through ConversationStore; legacy files
  still decode and the existing CloudSync JSON blob carries the new property.
- Lens, Voice and Models use the existing selection observer; camera start/stop,
  inference residency, permission and cancellation policies stay host-owned.
- Image studio, Device and Settings use the existing injected host sheets.
  Mac bridge opens the existing BridgePairingView. Manage conversations in the
  home overflow retains the full history-management screen.
- Visited workspaces stay mounted to retain chat drafts, attachments and scroll
  state. The host also saves presentation when chat becomes inactive.
- Sidebar search, collapse, selected-row state, edge opening, swipe dismissal,
  outside-tap dismissal and accessibility escape are connected. The dismissal
  target is the full exposed page, with hidden background content excluded
  from accessibility traversal.
- Voice shortcut resumes an active session, starts one when supported, or opens
  voice setup. Microphone/speaker/end/minimize remain independent.

## Composer reference follow-up

The later composer screenshots add a 32-point native glass panel, a rounded
model selector, separate attachment and dictation controls, and a blue primary
control. Empty drafts open/resume Voice; written text or attachments show Send;
a running response shows Stop. Unsupported dictation stays omitted. The model
menu keeps its real selection, load, thinking and device actions.

Image attachments render actual local, downsampled thumbnails, each with an
independent 44-point removal target. Stable IDs and the host's immutable send
snapshot remain unchanged. Document chips preserve filenames and removal.
Leaving chat or opening the sidebar explicitly stops dictation and invalidates
pending permission callbacks while the view stays mounted for draft retention.

## Verification

26 distinct native UI flows passed across targeted runs, including the new
home/workspace routes, sidebar search/pin/open/dismissal, camera selection
lifecycle, draft/attachment retention, image thumbnails, Voice/Send/Stop, model
controls, compact composer widths, dark/OLED and large text. A failed outside-tap
check was corrected and rerun successfully; screenshot review also caught and
corrected clipped selection corners and fragmented large-text labels.

12 host contracts passed (10 Swift Testing plus 2 XCTest lifecycle checks), and
all 6 package contracts passed. Repository hygiene and whitespace checks passed.
Native captures: `build/native-ui-evidence/sidebar/`. Detailed test inventory:
`build/releases/build-41-verification.json`.

The simulator review host uses fixtures; real camera/audio/inference require
physical-device verification and are not represented as simulator-tested.
Mac pairing and existing host utility destinations are source-wired and compiled;
their complete production behavior remains a physical-device check.

## Build 41 release

The final Release archive and the repository's complete sideload packaging
script passed. The profile-less IPA is `OnDeviceMax-sideload-entitled-1.0.0-41.ipa`
(46,068,349 bytes), SHA-256:
`53bb9dbad00901f28084e43980bb381511b770d18b71ef1ae2ba89765616bbc4`.
Only `Payload/` exists at the archive root. Nested signatures, share extension,
frameworks, privacy manifest, identity, file-sharing flags and required app/
extension entitlements passed verification. Installation still requires the
installer to re-sign both bundles. All 440 recorded source/configuration hashes
matched at completion. No model weights, signed archives or credentials are
added to Git.

The versioned IPA was copied to the previously shared OnDevice Builds iCloud
folder. The copied SHA-256 matches and Foundation confirmed uploaded = true,
uploading = false, with no upload error.
