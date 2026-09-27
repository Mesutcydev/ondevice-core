# Interface consistency audit — 24 September 2026

The user's Codex, Cursor, Claude, and OnDevice phone captures were treated as visual references. The production app keeps its own navigation and visual identity. The current shell is `OnDeviceWorkbench`; there is no bottom tab bar.

## Patterns applied

| Area | Reference observation | OnDevice rule |
| --- | --- | --- |
| Navigation | The reference conversation screens keep one compact title and a leading menu control. | Primary workspaces use inline titles. The menu keeps its native toolbar size and the leading drawer remains the only workspace navigator. |
| Conversation | Replies use the readable screen width and the latest message ends close to the composer. | The thread has a six-point bottom anchor, the jump control stays near the latest message, and canvas, toolbar, and dock use one background. |
| Composer | A contained input sits immediately above the keyboard or bottom safe area. | The composer stays in the shared bottom inset; status appears once in the dock and the draft remains attached to the conversation. |
| Settings | Peers have matching insets, corner geometry, and row heights. | Settings pages use a 4-point grid: 16-point page inset and card corner, 52-point minimum row, 36-point icon. Navigation rows have no added chevron outside the card. |
| Appearance | A choice preview should read at a glance without consuming a screen. | Three theme previews are 96 points high; their content fits inside the preview. |
| Models | A pack entry should be comparable to a model row. | Installed Core AI packs use one actionable row. Selecting a capability excludes unrelated pack entries and exposes the empty result state. |

## Verification and limits

- The isolated `QA/NativeUI` simulator host rendered the drawer, chat, home, voice, Models, Device, and Appearance screens. Focused UI checks covered card proportion, sidebar controls, Appearance, and model filtering.
- The production iOS target compiled. Its Core AI dependency is device-only, so the simulator cannot establish pixel or runtime behavior for the production Settings sheet, Core AI inference, downloads, or attachments.
- The sideload IPA uses ad-hoc signing and requires installer-side re-signing. Hardware acceptance is still needed for real inference, files, camera, microphone, and every production utility destination.

Reference context: [Codex app](https://openai.com/index/introducing-the-codex-app/), [Cursor Mobile](https://cursor.com/mobile), [Claude for iOS](https://support.claude.com/en/collections/9879000-claude-for-ios). The phone captures supplied by the user are the direct source for screen geometry and content hierarchy.
