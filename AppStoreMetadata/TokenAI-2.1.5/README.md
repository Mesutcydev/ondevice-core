# Token AI 2.1.5 App Store text

On 2026-11-04, on the owner's request, App Store version 2.1.5
(`140d4f5c-0570-4bf9-8c5b-0d70afd36782`, PREPARE_FOR_SUBMISSION, copyright
"2026 Mesut Can Yagci", manual release) was created with description, keywords,
marketing URL and support URL copied from the live 2.1.4 in all 11 locales.
`copy.json` holds the What's New and promotional text then written to those
11 localizations.

What's New covers what TestFlight 2.1.5 (104) adds over the live 2.1.4, which
shipped build 100: Lens → Live with LFM3 Omni, "speak in lens" reading Lens
results and Live comments aloud, the Supertonic 3 and Paradee voices and the
KittenTTS/Kokoro "er" fix, the Apple, Parakeet, Nemotron and Whisper
speech-to-text choices, the Voices page fix (2.1.4 shows no installed voices),
and Clip's Record button. UI names follow the app's translations (Live/Canlı/
En vivo/مباشر/लाइव/ライブ; English where the app has no translation).

`create.json` records the version creation, `before.json` the localizations
right after creation, `upload-results.json` the 11 updates, `after.json` the
read-back, and `verified.json` the comparison: What's New and promotional text
match `copy.json`, and description, keywords and both URLs match 2.1.4, in
11/11 locales. No build was attached and nothing was submitted for review.

## 4 November 2026 — submitted for review

On the owner's request, build 104 (`7b89875e-1bc4-4a77-91ce-faac63a2508b`,
the newest VALID build) was attached to 2.1.5 and the version was submitted:
review submission `7a50bfba-f0f7-435f-8e6b-82b969247615`, WAITING_FOR_REVIEW
at 2026-11-04T19:51:27Z. `asc validate` reported 0 errors and 0 blocking items
(one warning: the asc catalog does not know the APP_IPHONE_DUO screenshot
type, which 2.1.4 shipped with). App Review contact and notes were carried
over unchanged from 2.1.4. Release type is manual: after approval the
version waits for the owner to release it. Files are in `review/`.
