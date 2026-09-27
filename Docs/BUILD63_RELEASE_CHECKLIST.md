# Build 63 release checklist

Source for the next sideload IPA. Package after the production compile and
simulator/unit checks. The build 62 IPA predates these changes. Real Core AI
inference requires the new IPA installed on a supported iPhone.

| User report | Change | Verification |
| --- | --- | --- |
| Import and Downloads buttons have different sizes | Equal-width actions; stack at accessibility text sizes | Narrow and large-text NativeUI review |
| Model folder import stopped working | Separate folder and file pickers; coordinated security-scoped copy | Files folder-selection flow and production build |
| Downloaded Core AI packs missing from Models home | Include installations in the Models snapshot and update on store changes | Production build; hardware check for real installations |
| Chat model choice is forgotten | Save explicit picker and Models selections; restore prior default on load failure | Focused state check and app relaunch on device |
| Composer text is too high and too close to the leading edge | Increase writing insets while retaining flexible height and Dynamic Type | NativeUI screenshot at phone width and larger text |
| Core AI replies show `<unk>`, missing spaces, and a simple follow-up fails | Decode the full token prefix, reject empty template output, present orphaned tool results as prompt text, and retry transcript rejections once with the latest turn | Decoder tests, production build, and Nemotron 3 Nano 4B conversation on device |
| New IPA must have correct sideload structure | Build with `scripts/build_sideload_ipa.sh` after all checks | Script's archive, entitlements, nested-signing, and IPA verification |

The production Core AI model runs only on a supported iPhone. Simulator UI
fixtures cannot prove model quality or the real pack's inference behavior; a
Nemotron conversation must be checked after installing this IPA.

## Build 63 result

- Release archive and the repository's eight-step IPA verification passed.
  `build/releases/OnDeviceMax-sideload-entitled-1.0.0-63.ipa` contains the
  app and share extension under one `Payload/` root, with validated signatures
  and required entitlements. The installer must re-sign this profile-less IPA.
- The focused Files picker test selected and returned a model folder. Models
  action sizing and Core AI catalog placement passed at phone widths and large
  text sizes. Composer keyboard and large-text checks passed.
- The focused Core AI streaming decoder suite passed (2 tests). The Release
  production app compiled and archived with the final source changes.
- A real Nemotron 3 Nano 4B conversation remains a device acceptance check:
  test a short reply, a follow-up like “Go,” and a restart with the saved
  default model. The Core AI runtime cannot run in the simulator fixture.
