# TestFlight chat and GitHub update — 2026-10-10

The owner requested a new TestFlight build containing the latest changes.
Apple confirms **1.0.1 (2)** is **VALID** and **IN_BETA_TESTING** for the
existing internal **Me** group, which has access to all builds. English test
notes were published and verified. External state is `READY_FOR_BETA_SUBMISSION`.

- App: `6818199563`, bundle `com.mesutcydev.ondevicemax`.
- Owner team: `PUH4GMFV56`.
- Build ID: `2db1bae8-7be6-437e-a673-3326210bfc57`.
- Apple build upload time: **October 10, 2026, 19:39:41 Europe/Istanbul**.

The model picker is back at the top for local and API models, shows only the
model name, and uses native provider/model rows. The assistant sparkle badge
is removed. Waiting, reasoning and answer streaming retain the timed reasoning
row and animated reply bar, with the existing composer and scroll behavior.

GitHub & tools is available in Settings and **off by default**. Its quiet chat
context row opens the repository and branch selector. Tools access the selected
scope; staged edits stay in a conversation draft until reviewed. Publishing,
branch creation, pull requests and forward reverts require approval. GitHub
credentials use device-only, when-unlocked Keychain storage without a plaintext
fallback. See [GitHub tools](GITHUB_TOOLS.md) for sign-in and behavior details.

## Candidate verification

Both the app and share extension report 1.0.1/build 2. A fresh archive and signed
App Store export passed with shipping Xcode **27A266a**, the public model policy,
owner-team distribution profiles and Production CloudKit. Resource, privacy
manifest, signature, entitlement and Foundation Models import checks passed.
All **660** captured source inputs and **18** pinned package checkouts stayed
unchanged through packaging and upload; both package lockfiles agree.
The generated project used for compilation was verified unchanged afterward.

The latest **36** focused checks (38 executions with parameter cases),
production/QA compile gates, repository validation, catalog invariants and all
**35** model download probes passed. See the
[chat and GitHub QA record](CHAT_GITHUB_QA_2026-10-10.md) for tests and screenshots.
GitHub requests used mock transport, without real credentials or repository
mutation. Live GitHub sign-in, organization policy, branch protection and
physical-device inference remain device acceptance checks.

IPA: `build/appstore/1.0.1-2/export/OnDeviceMax.ipa` (**85,413,208 bytes**).
SHA-256: `0a3b52d38c39fe061c62d117088a077ce1eafdc37a5d3cf3bfd6a061aba1d0ea`.
The local checksum was verified before upload. Server checksum verification
was requested, but Apple's API supplied no checksums. Build and upload evidence
is retained under ignored `build/appstore/1.0.1-2/` and
`build/testflight-1.0.1-2-2026-10-10/`, including
`upload-verification-summary.json`.

[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).
