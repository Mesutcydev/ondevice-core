# Local classifier host adapter

The host supports Julia and Laya encoder decisions separately from text
generation. It returns option probabilities, a choice ID, an expected rubric
index, or a true probability. Laya also returns an advisory direct-answer
probability. It never executes tools from that prediction.

## Backends

`CoreAIClassifierRuntime.makeAdapter` accepts an already admitted `AIModel`,
the selected bundle's `metadata.json`, and a local tokenizer callback. Actual
function descriptors must match the published v0.2 encoder contract. Julia
runs one graph; Laya also runs its act graph.

`CoreMLJuliaClassifierRuntime.makeAdapter` supports the Julia Core ML export
already used in the owner's MatchRater app: `input_ids [1,L]` and `qtype [1]`
int32 inputs, with `scores [1,L]` output. It sends the real sequence without
padding and preserves the existing CPU-only policy. Defaults are a 2,048-token
window and a 512-token head budget. This is a different artifact from the
public Julia Core AI pack.

Both factories require a safety callback. The host must load through its
existing memory admission and coordinated runtime handoff, retain the model
for the operation, and recheck `DeviceSafetyMonitor`/memory/cancellation policy
before each graph call. Neither factory loads weights or creates another
residency owner. Do not run the same model through another adapter concurrently.
On background, stop requests, cancel, wait for submitted inference to drain,
then release the adapter/model through the existing unload path. Cancellation
discards late results; it does not promise to interrupt a submitted graph.

## Host call

After the host has admitted the model and loaded its local tokenizer:

```swift
let adapter = try CoreAIClassifierRuntime.makeAdapter(
    model: admittedModel,
    metadata: metadata,
    encode: encodeWithoutSpecialTokens,
    checkSafety: recheckHostSafety
)
let answer = try await adapter.classify(
    state: message,
    question: .choice(instructions: "Choose the message category", options: [
        .init(id: "question", description: "A request for information"),
        .init(id: "feedback", description: "Feedback about a product")
    ])
)
```

For the existing Core ML Julia model, use
`CoreMLJuliaClassifierRuntime.makeAdapter(model:encode:checkSafety:)`. The
MatchRater tokenizer's `encode(String) -> [Int32]` can be supplied directly:
`encode: { tokenizer.encode($0) }`. Its binary resource and private model
remain user-supplied local assets. No private source, weights, football data,
signed model updates, or backend credentials are bundled here.

For an HF tokenizer, load from the selected local `tokenizer/` directory and
encode each piece with `addSpecialTokens: false`. Do not use a chat template
or implicitly add BOS/EOS. Check tokenizer parity for each new checkpoint.
The injected closure must be safe to call from the adapter's actor.

The installed host uses `CoreAIClassifierTokenizer` for the published
Gemma-style contract: local JSON, added-token stripping, Metaspace, ranked
token-ID merges and UTF-8 byte fallback. Existing Hub parsing preserves
byte-distinct vocabulary keys. Empty text produces no token. This avoids
the general tokenizer's empty-piece and canonically equivalent Unicode
differences; the checkpoint tokenizer matches all 971 existing MatchRater
reference cases. Julia and the selected Laya pack publish identical tokenizer
JSON (SHA-256 `609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f`).
Tokenizer loading runs off the main actor and drains on cancellation.

## Strict protocol

The row is CLS, type/question text, SEP, each MASK and option text, SEP, state
text, SEP. Option text starts with one space. Marker positions are recorded
while assembling the row. Core AI right-pads to the declared window; Core ML
receives only the real prefix.

Julia uses choice descriptions, rubric entries, and false/true descriptions
without labels. Laya uses `id: description`, `level i: description`, and its
published false/true criteria. Substituting one formatter for the other changes
the model's input. Option order is preserved; the first tied option wins.
Scores are the probability-weighted zero-based rubric index, not rounded.

The host refuses duplicate/empty choice IDs, empty options, counts outside
2–20, incomplete boolean criteria, reserved MASK text/tokens, invalid token
IDs, options longer than 48 tokens, and head/state overflow. It never clips
a question or state. Pre-serialize structured states yourself: Julia publisher
parity requires Python-style JSON spacing and preserved key order.

`.source` is the default calibration. Julia uses T=1 and has no fitted
calibration. `.published` can use Laya's declared temperatures and option-count
buckets. Its act features always use raw T=1 probabilities before answer
calibration. A private tuned scorer requires its own versioned calibration
policy; do not infer one from the base Julia contract.

## Library and verification

Classifiers have a separate category and cannot become Assistant choices or
auto-load as chat. Encoder imports persist classification capability, zero
generated tokens and the actual window. Malformed/unknown encoder contracts
are refused. The public Julia entry remains in the separate Mac-only catalog;
the iPhone store refuses that catalog pack. The active native Models library
shows both Laya and Julia under **Classifiers** in **Discover** before any
download. Laya uses the validated Core AI downloader, with live progress,
pause/resume and cancellation; Julia is marked Mac-only with no iPhone
download action. Installed encoder packs remain in the Classifiers filter,
including validated custom imports. Selecting Classifiers with no installed
classifier opens Discover. The separate Core AI pack browser also includes
classifiers and retains their platform restrictions.

## Using installed classifiers

In Models → On device → Classifiers, **Use** opens the retained Classifiers
workspace and activates the selected installed model. The leading sidebar
also opens Classifiers; there, **Activate model** explicitly loads the selection.
Activation drains the other runtime through `ModelResidency`, applies live
`MemoryAdvisor`/`DeviceSafetyMonitor` admission, and specializes the local
Core AI asset with GPU preference. The local Hugging Face tokenizer encodes
without special tokens. No weights are downloaded by activation or inference.

The native form adapts between Choice (unique ID/description options), Score
(ordered rubric, zero-based expected index), and Yes/No (both criteria).
Sentiment, message-intent, relevance and yes/no templates remain editable.
After activation, token validation uses the actual tokenizer and model window;
published calibration appears only when the contract supplies it. Results
show every probability, the typed decision and Laya's advisory direct-answer
probability. Export shares result JSON only when explicitly requested.

Stop discards late output and keeps the operation busy until it drains. Unload,
runtime replacement, background and emergency cleanup cancel and drain the
classifier load/inference before releasing its model. Classifiers share the
Core AI residency owner with Assistant. They cannot become chat selections.

Authenticated local functions are `GET /v1/classifiers`,
`POST /v1/classifiers/activate` and `POST /v1/classifications`; see
[the API guide](AGENT_INTEGRATION.md). Classification requires the requested
model to be active and never silently loads or downloads it. API and UI use
the same typed adapter, operation state and safety gates. There is no automatic
conversation router or classifier-driven tool execution.

```bash
./scripts/test_coreai_classifiers.sh
./scripts/verify_zoo_catalog.sh
python3 scripts/verify_zoo_downloads.py
# Optional: use the owner's existing private assets on this machine.
./scripts/test_matchrater_classifier.sh /path/to/MatchRater
```

The optional check compares the existing tokenizer with its saved fixtures,
compares the new row builder with MatchRater's encoder fixtures, and checks
real CPU Core ML readouts against direct predictions. It compiles a temporary
Mac model and deletes it afterward. It prints counts/numerical differences
without request text or output content. Hardware Core AI parity and physical
iPhone memory/thermal/background behavior remain release gates.

`QA/NativeUI` compiles the production catalog and library projection and tests
classifier visibility, download intent, installed management, Assistant
exclusion, Mac availability and transfer-state actions without network calls
or inference. Build 77 includes the library visibility correction; build 76
contained the adapters but omitted uninstalled packs from the active library.
Build 78 adds activation, the native task workspace and local classifier functions.

The isolated review host's Laya metadata fixture comes from revision
`3fe58a5ed7857b41f5c7ba8c0f46ce420b42cf02`,
`ios-h18p/wfp16-s512/metadata.json` (Apache-2.0). Its tokenizer/graph closures
are explicit fixtures, so those UI runs do not establish physical GPU parity.

Public contracts: [Julia](https://huggingface.co/mlboydaisuke/Julia-1-CoreAI),
[Laya](https://huggingface.co/mlboydaisuke/Laya-Multilingual-CoreAI), and
[the zoo](https://github.com/john-rocky/coreai-model-zoo).
