# OnDevice Max Privacy Policy

_Last updated: 2026-10-10_

OnDevice Max is a local-first iOS app derived from iOS Local LLM. AI inference
and app storage are local by default. The project does not operate an account system, analytics
service, advertising service, or telemetry backend.

## What iOS Local LLM does NOT do

- The project does not collect personal information through an operated backend.
- We do not require an OnDevice account or sign-in. Optional providers and
  support destinations can require their own accounts.
- We do not include analytics, advertising SDKs, or third-party trackers.
- We do not send your conversations, photos, code, or voice to an iOS Local LLM-operated service.
- The project cannot inspect content stored only on your device. Information
  you choose to post to the project for support is described below.

## What stays on your device

- **Conversations**: stored locally in `~/Documents/conversations.json` with iOS at-rest encryption (file-protection class: "complete unless open").
- **Memories** ("remember this about me" facts): stored in `UserDefaults`, never uploaded.
- **Snippets**: same as memories.
- **Models**: downloaded from huggingface.co to `~/Documents/HFModels/`. A
  download uses HTTPS and may include a Hugging Face token if you explicitly
  save one for gated repositories.
- **Photos, files and shared content**: selected attachments and analysis history
  can be stored locally. The share extension stages content in the protected
  App Group container for receipt when you open OnDevice Max. Unreceived share
  entries expire after 24 hours; the wipe action clears staged shares.
- **MetricKit diagnostics** (crash/perf reports): stored locally for your reference. Apple aggregates these system-wide; that's an OS behavior, not ours.
- **Parental controls**: an optional parent PIN is stored as a salted derived
  value in device-only Keychain storage, with restrictions and retry limits.
  The app does not transmit the PIN. Clearing app data preserves these controls;
  changing or removing them requires the parent PIN.
- **Generated images**: results are stored locally for viewing and sharing.
  Copies you export to Photos or another app are controlled by that destination.

## When iOS Local LLM DOES talk to the network

The app can use the network for features you choose to enable or requests you
approve:

1. **Searching Hugging Face** in the Download Center.
2. **Downloading a model** after you choose it.
3. **Web search** when you enable it and submit a query. The configured search
   provider receives the query under its own privacy terms.
4. **Mac Bridge and Local API Server** when you enable them. Requests are sent
   between devices on your local network.
5. **iCloud sync** when you enable it.
6. **External documentation and links** when you choose to open them.
7. **Apple Private Cloud**, where available in an Apple-authorized build, only
   after you select it and accept its separate privacy consent. The prompt and
   included conversation context are sent to Apple's Private Cloud Compute
   service for remote inference under Apple's privacy practices. Local models
   never silently fall back to this service.
8. **API providers** after you configure an endpoint, select an API model, and
   accept its separate disclosure. Requests can include conversation text,
   system instructions, tool results, attached file excerpts, and supported
   images. The selected provider and any model operators it routes to apply
   their own privacy, retention, and billing terms. API keys are stored in
   device-only Keychain storage. Refreshing a model catalog sends the credential
   and request metadata, without conversation content. Saving configuration or
   opening the picker makes no request. Local inference never silently falls
   back to an API provider. Custom HTTP endpoints are limited to trusted private
   networks; their requests and credentials are unencrypted in transit.

9. **GitHub repository tools**, off by default. Connecting GitHub sends
   authentication and request metadata to GitHub. After you enable tools and
   select a repository/branch, GitHub receives scoped file/API requests and
   approved commits, branch creation, pull requests or reverts. Credentials
   remain in device-only Keychain and are never sent to a chat model. Staged
   file snapshots are protected with the conversation store. An API chat model
   receives included repository excerpts and tool results under its separate
   disclosure. Disconnecting deletes the saved GitHub token and turns tools off.

The app includes a network-activity indicator for requests made through its
monitored networking layer. Treat it as a useful diagnostic, not as a
system-wide packet monitor.

### Search providers and fetched websites

An enabled search provider receives the query, request metadata, and, where
configured, your provider API credential. A query proposed by the local assistant
may contain information from your conversation. Read the request before approving
it, or disable web access. An “Always Allow” setting permits subsequent requests
without an individual approval prompt. Fetched websites receive their URL request
and network metadata such as your IP address.

Provider retention varies; local AI does not make these requests private:

- [Brave Search API](https://api-dashboard.search.brave.com/app/documentation/general/privacy-policy)
  documents query retention of up to 90 days; zero retention requires a qualifying
  enterprise arrangement.
- [Tavily](https://www.tavily.com/privacy) describes query collection, possible
  service improvement use, and limited sharing with search index providers.
- [Exa](https://exa.ai/privacy-policy) applies its privacy terms to search API use.
- [DuckDuckGo](https://duckduckgo.com/privacy) applies its terms to the optional
  experimental HTML search integration.
- For SearXNG and custom endpoints, the operator you select determines retention
  and access. OnDevice cannot verify an arbitrary endpoint's practices.

## iCloud sync (optional, off by default)

If you turn on "Sync conversations to iCloud" in Settings, saved conversations,
including any persisted presentation or drafts in their stored record, are
saved to your **private CloudKit database** associated with your Apple account.
Apple operates this storage; the project does not have access to that private
database. You can turn sync off and remove the cloud copy through Settings.
Removing local content or uninstalling does not automatically remove that copy.

## Children's privacy

The project operates no personal-data backend. Optional network features send
requests to providers under the same terms described above. A parent can set a
PIN to restrict image generation in this app. These controls do not verify age
and do not replace iOS Screen Time. Separate app safeguards add chat safety
instructions and image-request phrase checks locally. They do not reliably
classify every request or generated image. Reporting opens the support website
only after your action; no prompt, conversation, image, or diagnostics are
attached automatically.

## Your control

- Settings provides controls for clearing local app content and credentials.
  The parent PIN and restrictions are intentionally preserved by data clearing.
- Uninstalling removes the app sandbox. Keychain records can survive uninstall;
  turn off parental controls with the parent PIN before uninstalling if you want
  to remove that record. Exported content and optional iCloud copies require
  deletion in their respective destinations.

## Models

iOS Local LLM can run third-party models through Apple's MLX framework and other
local runtimes. Models are subject to their own licenses and may be open
source, source-available, community-licensed, non-commercial, or research-only.
We do not relicense them.

## Permissions

Camera, microphone, speech recognition, selected photos, saving generated
images to Photos, and local-network access support the features you choose.
You can change permissions in iOS Settings. Permission requests do not grant
the project access to your content.

## Contact

The published privacy and support pages are
[OnDevice Max privacy](https://ondevice.fun/privacy/) and
[OnDevice Max support](https://ondevice.fun/support/). Cloudflare hosts these
pages and processes ordinary request metadata to deliver and secure the site
under [its privacy policy](https://www.cloudflare.com/privacypolicy/).

If you choose to open a GitHub issue for support or a privacy question, GitHub
processes it under [its privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).
Public issues and attachments are visible to others. The project can read and
respond to what you choose to post. Do not include credentials, private app
content, or personal information in a public issue.
