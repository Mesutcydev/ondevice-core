# Privacy Policy

**Last updated:** October 26, 2026

Token AI runs AI locally by default. The project operates no account, analytics, advertising, or inference backend and does not sell personal data. Optional network features send requests to providers, which may collect and retain them as described below.

## 1. Project-operated collection
The project does not operate a service that receives the following content. Optional providers have separate collection and retention practices described below.
- We do **not** collect images, video, or photos captured by the camera.
- We do **not** collect any text you enter, including chat conversations with the on-device assistant.
- We do **not** collect analytics, telemetry, crash reports, device identifiers, advertising identifiers, or any other usage data.
- The project operates no cookie or web-beacon tracking service. Optional providers and websites apply their own privacy practices.
- We do **not** sell or rent your data. Providers receive only the information needed for the optional network features you choose below.

## 2. What stays on your device
- **Camera content** is processed locally. Captures, selected attachments, and analysis history may be retained locally by the features you use.
- **Photos and attachments** you select can be retained locally with your conversations or analysis history. Shared content is staged in the app's protected App Group container so the app can receive it when opened.
- **Chat conversations** with the Assistant are stored locally in the app's sandbox. You can delete them at any time. The app doesn't sync them to iCloud or any other service; like other app data, they can be included in your device backups. Apple Private Cloud is described below.
- **Downloaded AI models** are stored in the app's sandbox and execute locally. Model downloads require network access.
- **Parental controls** store a salted derived parent PIN, restrictions, and retry limits in device-only Keychain storage. They are not transmitted and are preserved when app data is cleared. Changing or removing controls requires the parent PIN.
- **Generated images** are stored locally for viewing and sharing. Copies exported to Photos or another app remain under that destination's control.

## 3. Network usage
The app connects to the network only for explicit features:
- **Model search and download:** Hugging Face receives the request. A saved Hugging Face token is included only when required for a gated repository.
- **Web search and fetch:** The configured provider receives a search query, request metadata, and your provider credential where configured. An assistant-proposed query can include conversation information. “Ask Every Time” requests approval; “Always Allow” permits later requests without separate approval. Fetched websites receive their URL request and network metadata.
- **Mac Bridge and Local API Server:** When enabled, paired clients communicate with the app over your local network.
- **Apple Private Cloud:** In builds with Apple's entitlement, selecting this model requires a separate privacy consent. The request's prompt and included conversation context are sent to Apple's Private Cloud Compute service for inference under Apple's privacy practices. This is remote inference, and local models do not silently switch to it.
- **API providers:** After you configure and select an API model and accept its separate disclosure, the selected endpoint receives included conversation text, system instructions, tool results, attached file excerpts, and supported images. The provider and its model operators apply their own privacy, retention, and billing terms. API keys stay in device-only Keychain storage. Catalog refresh sends credentials and request metadata without conversation content; saving settings and opening the picker make no request. Local models never silently switch to an API provider. Custom HTTP endpoints on trusted private networks are unencrypted in transit.
- **External documentation and links:** These open only after your action.
- **GitHub repository tools:** Off by default. After you connect GitHub, enable tools and select a repository/branch, GitHub receives authentication, request metadata, scoped file requests and approved commits, branches, pull requests or reverts. Credentials stay in device-only Keychain and never enter chat model requests. File edits remain a protected conversation draft until review. An API model receives included repository excerpts/tool results under its separate disclosure. Disconnecting deletes the saved token and turns off GitHub tools.

There is no Token AI telemetry channel, remote configuration service, analytics SDK, or advertising SDK.

Search providers can retain requests. Brave Search API documents query retention up to 90 days unless a qualifying enterprise zero-retention arrangement applies. Tavily describes query collection, potential service improvement use, and limited sharing with search index providers. Exa and DuckDuckGo apply their published policies. SearXNG and custom endpoints apply the selected operator's practices. Provider policy links are in the public Privacy Policy; Token AI cannot promise zero retention for these optional features.

## 4. Permissions we request
- **Camera:** Required to capture frames for live analysis. Disable in iOS Settings any time; the app will continue to work with imported photos only.
- **Photo Library:** Optional. Only requested when you tap the photo picker. The app accesses only photos you explicitly select.
- **Microphone and speech recognition:** Used when you start a voice conversation or dictation. Local speech engines process audio on the device.
- **Local network:** Used when you enable the Local API Server or paired Mac bridge, or choose a custom API endpoint on your private network.
- **Save to Photos:** Used when you choose to save a generated image.

## 5. Children
The app is not directed at children under 13. The project operates no personal-data backend, but optional features send requests to providers under their privacy terms. A parent can set a PIN to restrict image generation in the app. Parental controls do not verify age and do not replace iOS Screen Time. Separate app safeguards add chat safety instructions and image-request phrase checks locally; these are not reliable classifiers of every request or generated image. Contact us via the Support link for questions.

## 6. Third-party AI models
The app uses third-party AI models that run on your device. We are not the authors of these models. Each model's license, source repository, and citation is shown in **Settings → Legal → Attributions**. A model may be open source, source-available, community-licensed, or restricted to research use; review its terms before downloading or using it.

## 7. Hugging Face downloads
When you tap "download" on a Hugging Face model, your device makes HTTPS requests to `huggingface.co`. We do not control Hugging Face. Their privacy policy and terms of service apply. If you save a Hugging Face token for a gated repository, the app stores it in the Keychain and sends it to Hugging Face for authorized requests; Token AI does not receive it.

## 8. Apple frameworks
The app uses Apple-provided iOS frameworks (Vision, Speech, Core ML, MetricKit, ActivityKit). These frameworks operate under Apple's privacy practices. **Speech recognition is forced on-device** wherever the device supports it (recent iPhones).

## 9. MetricKit diagnostics
iOS periodically sends MetricKit reports (crash, hang, CPU usage) to the app for the user's own diagnostic use. These reports stay on the device — we do not collect or transmit them. You can view and delete them in **Settings → Diagnostics**.

## 10. Network-activity indicator
A live indicator in the assistant tab reports requests made through the app's monitored networking layer. It is a useful diagnostic, not a system-wide packet monitor.

## 11. Data retention
Conversations are stored in the app sandbox with file protection (`completeFileProtectionUnlessOpen`). Settings offers local data-clearing controls. The parent PIN and restrictions are deliberately preserved by data clearing. Uninstalling removes the app sandbox, but Keychain records can survive; remove parental controls using the parent PIN before uninstalling to remove that record. Exported content and device backups require deletion in their respective destinations.

## 12. Your rights
The project operates no personal-data backend. Local content is controlled on your device. For information transmitted by optional features, contact the receiving provider about its access, correction, and deletion procedures. Contact us via the Support link for questions about the app.

## 13. Changes
If we change this policy we will update the "Last updated" date and re-prompt for acceptance inside the app.

## 14. Contact
Questions: see Settings → Legal → Support.

