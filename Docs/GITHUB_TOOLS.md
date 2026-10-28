# GitHub repository tools

GitHub tools are optional and **off by default**. Enable them in Settings →
Models & AI → API settings → GitHub & tools. Connect with GitHub device sign-in
or a fine-grained token, then select a repository and branch using the quiet
context row below the chat's top model picker. The model pill shows only its
name; the composer, sidebar, scroll behavior and reply animation are retained.

Selections and drafts belong to each conversation. New chats have no repository.
Restoration makes no network request. Changing repositories stops the active
reply and requires committing or discarding its draft. After reconnecting,
“Use this repository with…” explicitly re-authorizes the saved scope and
preserves edits; it verifies access to that repository and branch.

Device sign-in currently uses SiteAgent's working public OAuth registration.
The authorization sheet explains why GitHub names SiteAgent. OnDeviceMax keeps
its own connection identity and token. `GitHubOAuthClientID` in `project.yml`
can be replaced by a dedicated registration with device authorization enabled.
No client secret is required or embedded. Temporary authorization codes stay
in memory. Polling handles pending, slowdown, expiry, cancellation and brief
background time while approving in Safari.

Production credentials use a separate, nonsynchronizing Keychain service with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. There is no plaintext fallback.
UserDefaults stores only the opt-in flag and public account metadata. Tokens
never enter prompts, logs or exports. Disconnecting revokes app-side access
even if Keychain deletion fails; successful disconnect and Wipe app data delete
all saved GitHub credentials. Failures report safe messages without server bodies.

## Tools and review

| Tool | Behavior |
| --- | --- |
| `list_files` | Folder or bounded recursive tree, including staged edits |
| `read_file` | UTF-8 file with SHA256 and masked detected credentials; reads the staged overlay |
| `read_file_range` | A numbered range of up to 200 lines with detected credentials masked |
| `repository_info` | Selected scope, current commit, visibility and write permission |
| `list_branches` | Bounded, paginated branches in the selected repository |
| `write_file` | Stage new or updated text |
| `replace_text` | Exact replacements with occurrence count and optional SHA256 |
| `delete_file` | Stage deletion |
| `move_file` | Stage an atomic source deletion/destination addition; preserve executable mode and reject overwrites |
| `scan_secrets` | Scan up to 20 specified files locally; report kinds and line numbers, never values |
| `redact_secrets` | Stage detected credential removal after checking the exact file SHA256 |
| `audit_secret_history` | Read at most 10 path-changing commits for each of five specified files on the selected branch |
| `upload_attachment` | Stage actual user-selected bytes or image thumbnails |
| `search_code` | Repo-scoped GitHub search; its index uses the default branch |
| `git_log` | Recent commits on the selected branch |
| `git_diff` | Draft snapshots or a bounded GitHub comparison |
| `check_run_status` | Check runs for a commit |
| `workflow_status` | Last ten workflow runs on the selected branch |
| `request_user_approval` | Review the immutable staged draft |
| `create_branch` | Review creation, then select the new branch |
| `open_pull_request` | Review a PR from the selected branch to a chosen base |
| `revert_last_commit` | Review a forward revert of a single-parent commit |

API models and supported local tool-capable models use the existing text tool
bridge and global tool setting. Repository content is untrusted reference data.
All reads stay scoped to the selected repo. Paths, refs and origins are validated.
Only GitHub.com is supported. Ephemeral URLSession storage, bounded responses,
blocked redirects and static network activity labels keep credentials isolated.
There are no automatic write retries. Stop, workspace departure, background,
disabling tools and connection changes cancel repository operations.

Draft snapshots are AES-GCM encrypted before conversation persistence. Their
key uses a separate nonsynchronizing, when-unlocked, device-only Keychain item.
There is no plaintext fallback. Older draft snapshots migrate on the next save.
An unavailable key retains the ciphertext and readable chat history, blocks
repository operations, and requires unlocking/reconnecting on the original
device or explicitly discarding that draft. Wipe app data deletes the key.

Edits stay in a protected conversation draft until approval. Review shows the
destination, base commit, a numbered unified diff and full Before/After snapshots.
Each file can be included or excluded from a commit; excluded files remain staged
against the new commit. The complete draft still participates in approval validation. Binary
attachments show byte counts and SHA256. Publication creates blobs, a tree
based on the original tree, one commit, then a non-force branch update.
Executable modes are preserved; symlinks and submodules cannot be edited.
An advanced branch or changed account/draft invalidates approval without losing
the draft. Branch creation, PRs and reverts also require review. Reverts add a
commit and preserve history; merge and initial commits need manual handling.

Limits: 256 KiB text files, 1 MiB new attachments, 30 files / 2 MiB combined
draft snapshots, bounded listings/comparisons with truncation notices, and 25
tool steps per GitHub-enabled turn. Other turns retain the five-step bound.
Model residency, local inference, Mac pairing and local API policies are unchanged.
Detected credentials are masked in tool results, including diffs. Recognized
credentials in newly written text block staging and publication. The local
detector is deliberately conservative; it cannot prove a repository is clean.
Review snapshots remain available locally for the user and encrypted on disk.
Cancelled reviews keep the draft and the agent is instructed not to repeat an
approval request unless the user asks.

History audits are read-only and report their exact bounded coverage. They do
not inspect other branches, tags, PR refs or GitHub caches. Editing, deleting or
reverting a file preserves older commits. Repository-wide removal requires a
separate reviewed history-maintenance operation; credentials must also be
revoked with their provider.
GitHub receives authentication, request metadata and approved writes. An API
chat model also receives included repository excerpts under its disclosure.
Conversation exports and optional iCloud sync use the existing sharing rules.

## Code workspace

The sidebar's **Code** destination uses the same per-conversation GitHub service
as chat. It adds a folder browser, filename search, editable file tabs, a symbol
outline, line numbers, and restored cursor/scroll position. Staged proposals made
in chat also appear in the editor and can be revised before review. **Stage**
compares the exact editor baseline with the shared draft; it never publishes.

Select code and use Explain, Find and fix bugs, Refactor, or Add tests. Pin files
to context or mention `@Sources/Counter.swift`, `@Sources/`, or
`@"Docs/Getting started.md"`. Excerpts are bounded, marked as untrusted source,
redacted for recognized credentials, and prefixed with file/line references and
their base commit. Edited excerpts are labeled as working copies. The prompt is
appended to the current chat's composer for inspection, using its existing model
and inference policy. It is not sent automatically.

Open-file caching is opt-in. Edited drafts and the latest five explicit
checkpoints are AES-GCM encrypted locally using the existing device-only GitHub
snapshot key; files are excluded from backup. A stable editor ID separates two
conversations that select the same account/repository/branch. Closing edited
files, restoring checkpoints, and branch updates preserve a checkpoint first.
“Update from branch” requires a per-file Keep my edit / Use branch version choice
when the remote source conflicts with a staged or independent editor edit.
No refresh operation writes to GitHub, and an advanced branch still invalidates
commit approval. Wipe app data removes the workspace cache, checkpoints and
temporary exports along with the snapshot key.

The reading guide puts README files first and tracks bookmarks, line references,
and read/unread progress. HTML preview serves only opened workspace files from an
in-memory origin in an ephemeral WKWebView. Relative CSS/JavaScript are supported;
Fit, 390-point Phone and 768-point Tablet viewports, a bounded console and native
Markdown preview are included. CSP and navigation rules block remote resources,
requests, frames, forms and external navigation. ZIP and single-file export share
the actual open file content through the system share sheet. ZIP uses an original
STORE encoder; no dependency, template, or third-party UI was added.

Editor bounds: 30 open files, 256 KiB per UTF-8 file, 2 MB combined snapshots,
10 context files and at most 12,000 context characters (further reduced for the
selected model). Inline diffs are bounded to 6,000 input lines; complete
Before/After remains available for larger files. Listings disclose truncation.

## Validation and references

`QA/NativeUI` compiles production models, client, stores, service and views.
Mock contracts cover default-off access, scoped paths, credentials, safe errors,
exact edits, overlays, immutable approval, atomic commits, conflicts, cancellation,
reconnection, forward revert, device-flow responses and legacy histories. Native
flows cover opt-in, secure token entry, repo/branch selection, draft retention,
Before/After review, cancellation, commit confirmation and large text.
`CodingWorkspaceTests` also covers chat-isolated editor storage, offline positions,
encrypted/tampered snapshots, checkpoint recovery, manual request cancellation,
working-copy context redaction, exact staging and partial commits. Coding UI flows
exercise source editing, diff review, chat context, readable large text, checkpoint
recovery, relative CSS/JavaScript, ZIP export and WebKit's actual CSP violation
event for a blocked remote request.
The shared production parser recognizes repository calls in fenced, plain,
OpenAI-function and Hermes formats and excludes calls still inside reasoning.
Final contracts include a parsed read → stage → review round trip with no
remote writes. See the [chat and GitHub QA record](CHAT_GITHUB_QA_2026-10-10.md)
for the compile gates, focused checks, screenshots and motion evidence.
Mocks use no real credentials and publish to no real repository. Account-specific
sign-in, organization policy, branch protection and hardware inference remain
device checks. No dependency, copied SiteAgent source or image asset was added.

- [GitHub device authorization](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
- [GitHub REST API versions](https://docs.github.com/en/rest/about-the-rest-api/api-versions?apiVersion=2026-03-10)
- [Git trees](https://docs.github.com/en/rest/git/trees?apiVersion=2026-03-10)
- [Non-force reference updates](https://docs.github.com/en/rest/git/refs?apiVersion=2026-03-10)
