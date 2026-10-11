# Chat and GitHub tools QA — 2026-10-10

The current source implements the latest reference: the model picker stays at
the top for local and API models, shows only the model name, and uses native
grouped provider rows. The assistant sparkle badge is removed. The ruled
reasoning row includes elapsed time, and the existing reply bar is shared by
waiting, reasoning and answer text. The composer, conversation scrolling,
sidebar and leading keyboard hide key retain their existing roles.

GitHub & tools is an optional Settings feature, **off by default**. When enabled,
a quiet repo/branch indicator below the model picker opens the native selector.
Each conversation owns its selection and protected draft. The agent's tools
use that selected scope, and publishing, branch creation, pull requests and
forward reverts require review. Production tokens use a separate device-only,
when-unlocked Keychain service without a plaintext fallback. See
[GitHub tools](GITHUB_TOOLS.md) for behavior, boundaries and sign-in details.

## Verification

Production passed `build-for-testing` for generic iOS with signing disabled.
`QA/NativeUI` passed its Simulator compile gate using production components.
The app's CoreAI runtime is device-only; this is not a Simulator inference test.
Repository validation and `git diff --check` passed.

The focused checks cover **36 unique tests** (38 executions including one
three-case parameterized test), with no failures, skips or runtime warnings.
The result bundles below are complementary runs; repeated tests are counted
once in the unique total.

| Checks | Result |
| --- | --- |
| GitHub contracts, including model-format calls through the actual shared parser | 16 passed |
| Chat presentation and provider/stream identity contracts | 7 passed, including 3 parameter cases |
| GitHub native flows: default-off, selection, review, secure token entry, large text | 4 passed |
| API provider native flows | 4 passed |
| Waiting → reasoning → answer, Stop, tool details and compacted context | 3 passed |
| Latest reply/composer spacing and top model/persona picker | 2 passed |

The first regression run was followed by 18 focused checks after native tint
and singular-count polish. The final parser change was followed by all 16
GitHub contracts and both compile gates. The shared parser preserves existing
calculator, date/time, conversion, inline fences, nested JSON and reasoning
boundaries while recognizing the new repo tools.

The contracts use a bounded mock HTTP transport and in-memory fixture
credentials. No real token was entered and no live repository was mutated.
They verify scoped requests, safe errors, no writes before review, executable
file modes, non-force updates, advanced HEAD conflicts, exact replacement,
binary attachments, cancellation, reconnect authorization, forward revert,
device-flow states and Keychain failure handling. Account-specific OAuth,
organization restrictions, branch protection and physical-device inference
remain device acceptance checks.

Evidence is retained under ignored `build/`:

- `github-chat-verified.xcresult` — initial 34-test regression pass.
- `github-polish-verified.xcresult` — 14 GitHub contracts and 4 native flows.
- `github-parser-verified.xcresult` — final 16 GitHub contracts.
- `github-tools-production-build.log`, `github-tools-ui-final-build.log` and
  `github-tools-validator.log` — compile and repository gates.
- `github-chat-evidence/` — polished repo, settings, review, large-text, provider
  and streaming screenshots. The GitHub screenshots were refreshed after tint
  and count fixes.

## Motion review

| Before | After | Why |
| --- | --- | --- |
| An empty waiting reply had no reasoning row or reply bar | `ODReasoningBlock` renders the timer and `ODStreamingText` even before reasoning arrives | The first-response wait has the same visible activity affordance as later phases; see `ODReasoningBlock.swift:26` and `:59` |
| Separate answer/reasoning paths could omit the existing bar | Both use `ODStreamingCaret` | The shared 2-point bar retains the existing 1.2-second opacity pulse; see `ODChatActivity.swift:30` |
| A continuously animated retained workspace could keep updating while hidden | Leaf timelines pause when hidden or inactive; Reduce Motion keeps a static visible bar and dots | Continuous feedback stays local to small views and respects visibility and accessibility; see `ODChatActivity.swift:41`, `:166` |

**Performance:** the caret changes opacity only; dots use offset and opacity.
The transcript is not rebuilt for each pulse. The 1.2-second period is a
continuous generation indicator, not the duration of opening a menu or sheet.

**Interruptibility & timing:** lifecycle tests verify the transition through
waiting, reasoning and answer, frozen completed time, and removal of streaming
activity after Stop. The reasoning disclosure uses a short 180 ms ease-out
transition and removes movement under Reduce Motion.

**Accessibility:** decorative bars/dots are hidden from accessibility, the
streaming text remains a combined element, and motion pauses under Reduce
Motion. Native picker/review flows also passed at large text size.

**Decision: Approve.** Three full-resolution live frames of the waiting bar
were captured approximately 0.39 seconds apart. Mean luminance in the same
9 × 48-pixel bar region was 93.60, 54.82 and 105.28, confirming the visible
pulse. See `github-chat-evidence/agent-chat-pulse-{1,2,3}.png` and
`pulse-measurements.json`. This verifies the pulse, not an FPS or hardware
performance claim.

## Distribution state

The previously uploaded **1.0.1 (1)** predates these latest model-picker,
reasoning-bar and GitHub changes. Its historical release evidence remains in
[the earlier TestFlight record](TESTFLIGHT_CHAT_API_2026-10-10.md).
After the owner's request to upload the follow-up, both targets were advanced
to **1.0.1 (2)**. Apple confirms the new build is **VALID** and **IN_BETA_TESTING**
for the existing internal Me group. The latest changes are included in that
build; see the [new TestFlight record](TESTFLIGHT_CHAT_GITHUB_2026-10-10.md).
