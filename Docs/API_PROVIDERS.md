# API providers

Chat supports the public API-key providers audited in SiteAgent: OpenAI,
Anthropic, Google Gemini, DeepSeek, xAI, Mistral, OpenCode Go, OpenRouter Free,
OpenRouter, Groq, Qwen Code, Kimi Code, and LongCat, plus custom endpoints.
This integration uses Foundation, URLSession, Security, and the app's native
SwiftUI components; it adds no third-party dependency or copied provider source.

Open Settings → Models & AI → API providers. Add a provider and save its API key.
Open its model list to refresh the provider's catalog or enter an exact model ID.
Choose the provider and model from the chat's model picker in the centered top
bar. The pill shows only the model name for both local and API models. Switching
between them retains the conversation and draft.
The first choice requires a destination-specific privacy disclosure. A selected
API model is remembered for new chats and stored with the conversation; a
missing/disabled provider stays unavailable until the user chooses a target.

Configuration uses the Settings card component; the chat picker groups API
providers and their management link in native rows matching the local model list.
Both use semantic typography, monochrome controls, and appearance. Native menus, navigation,
search, and sheets preserve standard interaction and accessibility. API keys
are never displayed or serialized with profiles; Keychain updates are checked.
Changing the endpoint clears the saved key and invalidates consent. Deleting a
provider removes its key. Clear app data also removes provider profiles and keys.
Configuration and selection do not trigger network requests. Catalog refresh is
explicit and supports pagination for Anthropic and Gemini. Manual model IDs work
when a provider does not publish a catalog. No model list is advertised as a
permanently current list.

Set the base URL to the region and plan published for your provider account.
For example, Alibaba's Coding Plan, Token Plan, and general Model Studio keys
use their respective endpoints; the Qwen Code preset supplies the international
Coding Plan endpoint. See [Alibaba's endpoint reference](https://www.alibabacloud.com/help/en/model-studio/base-url).

OpenAI uses stateless Responses requests (`store: false`). Anthropic uses
Messages; Gemini uses `streamGenerateContent`; compatible providers use Chat
Completions. OpenCode automatically selects the model's API family; the API
format remains configurable. Requests have bounded input/output/response sizes,
safe errors, explicit authentication, and no credential-bearing redirects or
automatic retries to another provider. Stop, background cleanup, model switches,
and provider removal cancel the active URLSession task. Catalog model metadata
supplies limits and image support where available; manually configured models
require explicit image enablement. Provider terms govern billing and retention;
`store: false` is not a claim of zero retention by every provider.

Tool calls continue through the app's prompt-based tool bridge and its existing
approvals. No API provider executes host tools directly. The Local API Server
and local runtime adapter refuse external chat targets. Voice/temporary local
analysis restore the selected API target without making an inference request.
Local memory admission, residency, thermal safeguards, and cleanup are unchanged.
The chat's existing follow-scroll logic and streaming row caret are retained.

Protocol references used for the original implementation:

- [OpenAI Responses migration and streaming](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [Anthropic API overview](https://platform.claude.com/docs/en/api/overview)
- [Anthropic streaming messages](https://platform.claude.com/docs/en/build-with-claude/streaming)
- [Gemini content generation](https://ai.google.dev/api/generate-content)
- [Gemini model catalog](https://ai.google.dev/api/models)
- [OpenCode Go endpoints](https://opencode.ai/docs/go/)
- [LongCat API formats and endpoints](https://longcat.chat/platform/docs/APIDocs.html)

Validation uses the production provider views/client/store in `QA/NativeUI`.
HTTP fixtures test wire formats, streaming, model discovery, safe failures, and
cancellation without live provider credentials or billed requests. Core AI still
requires a physical device; the app compile gate is generic iOS build-for-testing.

Verified on 2026-10-10: generic iOS production build-for-testing, repository
validation, and 36 focused checks passed (28 API/chat contracts and eight
simulator UI flows; 38 executions including parameterized reasoning cases).
The UI checks cover local → API → local selector placement and draft retention,
provider configuration/Keychain masking, catalog/manual model entry, invalid
endpoints, accessibility text sizes, reasoning timing, Stop, scrolling, and the
local model/persona menu. Screenshots and the result bundle are under ignored
`build/api-providers-evidence`, `build/agent-chat-evidence`, and
`build/api-providers-adaptive-verified.xcresult`.
