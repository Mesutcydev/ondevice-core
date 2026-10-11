# Reasoning persistence and repository credential workflow — 2026-10-10

The user's pasted app conversation was treated as reference, not authorization
to execute its embedded commands or repeat its declined approval request.

## Behavior

`AssistantReplyPresentation` partitions live and completed replies consistently,
including leading whitespace, incomplete delimiters, implicit model reasoning,
multiple blocks and opaque fenced examples. `ODAssistantReplyLayout` retains the
same disclosure slot when the answer renderer changes. Reasoning starts collapsed
and can be opened during streaming; completion preserves that choice. The ruled
row, actual frozen time, streaming bar and scroll/composer behavior remain.
Tool handoffs keep their assistant message ID, thought content and metrics;
protocol JSON is kept in hidden model context. Stop also normalizes implicit
reasoning. Token arrivals and completion do not animate transcript layout.

The context-compaction notice shares the composer's outer 16-point page margins.
Its scaled symbol aligns with the first text baseline, wrapped text stays leading
aligned, and 12-point horizontal / 10-point vertical padding leaves the actual
compaction message readable. A single accessible label/value retains the full
message. No compaction estimates, model names or context logic were changed.
Native geometry checks compare both notice edges to the composer panel in dark,
light/320-point and accessibility text-size fixtures.

Eight additional repository tools provide metadata, branches, numbered file
ranges, staged moves, conservative secret scans, exact-hash checked redaction,
bounded history audits and workflow status. All tools use the user's selected
repository/branch, remain off by default, and retain cancellation and review.
History audits never rewrite remote history and report their limited coverage.

Detected credentials are masked in model-facing tool results and diffs, and
recognized credentials in newly written text block staging and publication.
The detector does not claim exhaustive coverage. Draft file snapshots use
AES-GCM with a separate device-only, when-unlocked, nonsynchronizing Keychain
key and no plaintext fallback. Existing snapshots migrate on their next save.
If a key is unavailable, ciphertext is retained and the conversation stays
readable; that draft cannot run tools or be approved until unlocked/reconnected
on its original device. User review is local and shows the full snapshots.

## Repository redaction

The current `Cesur2000/website` main branch was inspected through authenticated
GitHub requests. The scan covered 214 current text files up to 1 MiB, withholding
values from logs and reports. Known credentials were found in the deployment
guide and stream URL example comments. They were replaced with placeholders;
the TypeScript executable code stayed identical. A dependency-free credential
guard and read-only GitHub Actions check were added. The guard's seven fixtures
passed and its latest CI run succeeded after narrowing the stream URL pattern
to avoid a sitemap schema false positive.

Published commits: `51f4ce3e3d66774eecffc2e298c003a28ed2ee5e` and
`2ed4532b46401e9966fc5bb8732aa369cb9ff982`. The final main file snapshots and
[credential guard run](https://github.com/Cesur2000/website/actions/runs/38074060249)
were verified. No existing local website checkout or dirty files were reset.

A separate local history candidate inspected 739 commits from 55 branches,
rewrote 547 commits on 18 branches, and checked 1,094 affected-file snapshots.
It preserves other file trees, authors, dates and merge topology; invalidated
commit signatures are removed. Only the known values in the two affected paths
and commit messages were covered. Other historical files, PR refs, forks and
GitHub caches were not covered. Publication requires the owner's explicit
approval and an atomic push with a reviewed force-with-lease value per branch.
No remote history has been rewritten. Exposed credentials still require
revocation at the IPTV provider. See ignored `build/website-secret-audit/` for
the reports and review, which contain no credential values. The isolated Git
clone also retains original input objects and is restricted to the local user.

## Verification

The production generic iOS and `QA/NativeUI` build-for-testing gates passed.
CoreAI remains device-only; Simulator checks exercise production UI components
and mocked GitHub transport rather than inference or live account sign-in.
Repository hygiene and `git diff --check` passed. Tests use invented fixture
credentials; encryption contracts supply transient in-memory keys explicitly
because the unsigned Simulator fixture cannot access production Keychain.
Production Codable contexts always require Keychain and have no fallback.

The final sequential contract run passed 23 GitHub tests and 11 presentation
tests (the latter includes three parameter cases). Its initial UI run reported
one draft-value mismatch immediately after keyboard dismissal; the final UI
check now waits for keyboard dismissal to complete before checking retention.
The polish run passed all 11 native UI checks with zero failures, skips or
runtime warnings: five agent-chat cases, four GitHub cases, and two production
scroll/model-menu cases. Acceptance evidence is the passing contract suites in
`build/reasoning-tools-accepted.xcresult` and the complete passing UI bundle
`build/compaction-polish-native.xcresult`. Across those suites, 45 logical tests
passed (47 executions including parameter cases). Earlier overlapping Simulator
runs were interrupted by their competing test runners; those bundles are not
acceptance evidence.

Latest compile logs: `build/compaction-polish-production-build.log` and
`build/compaction-polish-ui-build.log`, both commands exited 0. The beta QA
compiler emitted existing actor-isolation/deprecation warnings and misleading
"exit code 0" diagnostic lines; the rebuilt app and test runner completed the
native checks. Hygiene log: `build/compaction-polish-validator.log`.

Original native screenshots were inspected under ignored
`build/reasoning-tools-evidence/`: `agent-chat-answer-streaming.png`,
`agent-chat-reasoning-retained.png`, `agent-chat-large-type.png`, and
`agent-chat-compaction-compact-light.png`. They show the matching notice/composer
edges, first-line icon, full wrapped message, retained reasoning and reply bar.

## Motion review

| Before | After | Why |
| --- | --- | --- |
| Live and final reasoning used different view branches | One disclosure slot persists in `ODAssistantReplyLayout.swift:25` | Completion retains expansion state instead of remounting the row |
| Live thoughts grew automatically and then collapsed | A collapsed 44-point row can be opened explicitly in `ODReasoningBlock.swift:22` | Tokens and completion do not shift the collapsed row |
| Tool calls deleted the thinking message | `AssistantActivity.retainReasoningForTool` retains its ID and thought block | Tool execution does not remove a visible reasoning row |
| Partial opening markers could briefly hide the row | `AssistantReplyPresentation` holds the waiting state for marker fragments | The first few streamed tokens do not cause a disappear/reappear cycle |

Performance: no animation is attached to token content or streaming completion.
The shared caret keeps its opacity-only pulse and visibility/Reduce Motion
policy; dots keep their existing leaf animation. The explicit disclosure uses
180 ms ease-out feedback and disables movement under Reduce Motion. Live
expanded thoughts use the existing bounded 1,200-character tail.

Accessibility: the disclosure is available while live and after completion,
exposes Expanded/Collapsed state, retains its identifier and minimum hit size,
and keeps decorative activity hidden from accessibility. Native checks assert
unchanged collapsed row height and position through the reasoning/answer
transition and retained expansion through completion. The screenshots verify
the retained rule and bar; they are not an FPS or physical-device performance
measurement.

Decision: **Approve** for the reasoning persistence and static notice polish.
No new token/completion animation is introduced in
`ODAssistantReplyLayout.swift:25`. Explicit disclosure feedback remains
interruptible, 180 ms ease-out (`ODReasoningBlock.swift:22`), and the existing
leaf caret animates opacity only with visibility and Reduce Motion handling
(`ODChatActivity.swift:41`). The compaction surface at
`ODChatActivity.swift:219` has no animation. The native checks and screenshots
support layout/state acceptance; frame-rate and physical-device performance
were not measured.

## Distribution

These follow-up changes are included in **TestFlight 1.0.1 (3)**, which Apple
confirmed **VALID** and **IN_BETA_TESTING** for the existing internal Me group.
The preceding build 2 predates this reasoning-persistence, compaction-layout
and repository-security follow-up. See the
[build 3 upload record](TESTFLIGHT_REASONING_TOOLS_2026-10-10.md).
