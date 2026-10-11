# Core AI model audit — 30 September 2026

The library now has **34 iPhone packs**, including six additional chat packs
and Laya's classifier. Julia is recorded separately as a **Mac-only Core AI
classifier**. The strict decision host supports both public encoder contracts;
a Core ML bridge also supports the Julia export already used in the owner's
MatchRater app. See [the adapter guide](COREAI_CLASSIFIER_ADAPTER.md).

This checks artifact compatibility, not model quality or physical-phone
inference in this app. No weights are part of the source distribution.
Downloads remain explicit, and classifiers cannot enter the chat picker.

## Scope and evidence

Hugging Face API searches for `CoreAI`, `coreai`, and `core-ai` returned 362
distinct IDs. Repository identity/tree/card data was inspected for 143
candidates: the existing catalog and repositories updated since 20 September.
Bundle metadata was collected for 141; two candidates did not complete that
collection. Matches include mirrors and non-Core AI artifacts. The
[zoo index](https://github.com/john-rocky/coreai-model-zoo/blob/main/models/index.json)
helped discovery; an index entry does not prove compatibility with this host.

All original 27 pinned packs have exact matching subtree byte counts. After
the additions, `verify_zoo_downloads.py` passed **all 35 pinned entries** (34
iPhone plus Julia): paginated trees, exact sizes, model resources, root-level
metadata/tokenizer for chat and classifier bundles, exported context bounds,
and direct ranged download URLs. Only small metadata files and 1 KiB download
probes were fetched; no full HF model weights were downloaded. These probes
do not verify every file's content hash. The full pinned inventory is in
[the audit record](audits/coreai-2026-09-30.json).

## Added chat packs

Every row has an Apache-2.0 license file, local tokenizer/chat template, a
v0.2 `kind: llm` bundle, running `position_ids`, float16 logits, and an iOS
limit of 4,096 tokens in `aether.json`. The existing Assistant policy still
applies its conservative 1,024-token total Core AI budget.

| Conversion | Selected subtree | Exact bytes | Pinned conversion revision |
| --- | --- | ---: | --- |
| [Granite 4.0 H 350M](https://huggingface.co/aether-models/granite-4.0-h-350m) | `ios-any-gpu` | 691,007,111 | `ea24ac837112b7b082e52cd51bc83b38467ae659` |
| [Qwen3 1.7B](https://huggingface.co/aether-models/qwen3-1.7b) | `ios-any-gpu` | 1,738,451,082 | `9424554369f1c4fd2f80af64847ba2d938e2c58a` |
| [Granite 4.0 1B](https://huggingface.co/aether-models/granite-4.0-1b) | `ios-any-gpu` | 1,743,936,100 | `2b5d83696b7455ee02a79596cd077a93a2e78ba9` |
| [EuroLLM 1.7B Instruct](https://huggingface.co/aether-models/eurollm-1.7b-instruct) | `ios-any-gpu` | 1,931,164,337 | `3ed1743a0b15f6d4950d523562aa42b114969fd8` |
| [SmolLM3 3B](https://huggingface.co/aether-models/smollm3-3b) | `ios-h18p-gpu` | 3,285,009,137 | `2d9e78f3665bd28ae73f9f44b22917f0b86f3491` |
| [Qwen3 4B Instruct 2507](https://huggingface.co/aether-models/qwen3-4b-instruct-2507) | `ios-h18p-gpu` | 4,041,759,267 | `1bd7de3abec265601b6d2473e7b6557223e2dbc1` |

Granite H includes convolution and SSM states alongside KV caches; the existing
pipelined engine preserves them. The other five use the ordinary KV contract.
H 350M is fp16; the others are weight-only int8. Compiled H18p packs are
hardware-specific. SmolLM3 requires the increased memory limit entitlement
already configured here; live admission can still refuse a pack.

Publisher phone T2 records report 19/19 cases for both Granite packs and
SmolLM3, 17/17 for EuroLLM, 18/19 for Qwen3 1.7B, and 17/18 for Qwen3 4B
Instruct. The latter two respectively fail `haiku-sea` and `think-prime`;
they are not perfect-parity conversions. These are another host's tests and
do not establish performance in this app. Thinking/tool flags follow the
declared templates; app-level decoding still needs device validation.

Source versions recorded in the selected `aether.json` files:

| Pack | Source checkpoint | Source revision |
| --- | --- | --- |
| Granite H 350M | `ibm-granite/granite-4.0-h-350m` | `3b17b717b8f2f5d305b0a92c1491e239aeda19c8` |
| Qwen3 1.7B | `Qwen/Qwen3-1.7B` | `70d244cc86ccca08cf5af4e1e306ecf908b1ad5e` |
| Granite 1B | `ibm-granite/granite-4.0-1b` | `6a7381ba1f54d684ff508d991aeb7dc580157103` |
| EuroLLM | `utter-project/EuroLLM-1.7B-Instruct` | `a25c7fa65fc2a644e6270b8940dbe295b51da681` |
| SmolLM3 | `HuggingFaceTB/SmolLM3-3B` | `a07cc9a04f16550a088caea529712d1d335b0ac1` |
| Qwen3 Instruct | `Qwen/Qwen3-4B-Instruct-2507` | `cdbee75f17c01a7cc42f958dc650907174af0554` |

## Julia and Laya

| Conversion | Selected subtree | Exact bytes | Pinned revision | Disposition |
| --- | --- | ---: | --- | --- |
| [Julia 1](https://huggingface.co/mlboydaisuke/Julia-1-CoreAI) | `macos/fp32-s1024` | 627,543,671 | `d1e943545c64e20e73a88ae1f890227c349e22ba` | Separate Mac-only classifier list |
| [Laya Multilingual](https://huggingface.co/mlboydaisuke/Laya-Multilingual-CoreAI) | `ios-h18p/wfp16-s512` | 681,051,433 | `3fe58a5ed7857b41f5c7ba8c0f46ce420b42cf02` | iPhone classifier category |

Julia is a 144M mmBERT-small decision encoder. The public export was published
today, has Mac GPU/CPU parity evidence, and no iPhone validation. Its source is
`SupersonicLabs/Julia-1` at `a85b127321d580d65176c89ced8273f305745d85`.
The host gathers marker logits and uses T=1 for choice, expected rubric index,
and true probability. No act graph or fitted calibration is part of this
export. Generic language-bundle loading is inappropriate.
[Julia contract](https://huggingface.co/mlboydaisuke/Julia-1-CoreAI).

Laya uses mmBERT-base and has published iPhone GPU evidence. It adds pooled CLS
and an act graph driven by raw probabilities; optional answer calibration
uses published temperature buckets. The publisher reports failed Neural
Engine parity, so use the selected pack's GPU path. Julia and Laya require
different option formatting. Both declare Apache-2.0; the mmBERT bases retain
MIT notices. [Laya contract](https://huggingface.co/mlboydaisuke/Laya-Multilingual-CoreAI).

The owner's existing MatchRater integration uses a different CPU-only Core ML
artifact with a flexible 2,048-token sequence, scalar `qtype`, and a custom
tokenizer. The new bridge accepts its already loaded model and tokenizer
callback. Locally, **971/971 tokenizer fixtures and 100/100 encoder fixtures
matched exactly**. Six real CPU Core ML predictions, including the question
types available in those fixtures, matched direct readout probabilities with
**zero difference**. Private weights, data, updates and implementation stay
in that project. This does not make the public Core AI pack iPhone-validated.

## Existing catalog corrections

Nine entries advertised 8,192 tokens while pinned export metadata declared
4,096. Corrected IDs: `zoo-qwen35-0.8b`, `zoo-lfm25-1.2b`,
`zoo-granite-4.0-h-1b`, `zoo-qwen35-2b`, `zoo-bitcpm-8b`, `zoo-lfm25-2.6b`,
`zoo-nanbeige41-3b`, `zoo-nemotron-3-nano-4b`, and `zoo-nanbeige42-3b`.

MiniCPM5 1B's fixed single-token iOS path has the existing runtime's 1,024-token
limit, now reflected in the catalog. Source context, export capacity and app
memory/correctness policy are separate limits.

FastContext's label now explicitly says MIT. Youtu's notice calls out its
European Union use restriction; it is not Apache/MIT. BitCPM and Youtu retain
their embedded custom-kernel contracts. An embedded kernel alone is not a
reason to withdraw those packs. [FastContext](https://huggingface.co/mlboydaisuke/FastContext-1.0-4B-CoreAI),
[Youtu](https://huggingface.co/mlboydaisuke/Youtu-LLM-2B-CoreAI),
[BitCPM](https://huggingface.co/mlboydaisuke/BitCPM-8B-CoreAI).

## Deferred candidates

| Candidate/family | Reason and next work |
| --- | --- |
| [Agents-A1 4B](https://huggingface.co/mlboydaisuke/Agents-A1-4B-CoreAI) | Large Mac conversion without a verified phone tree; await iOS artifacts and peak-memory evidence. |
| [OpenThai SystemOne](https://huggingface.co/mlboydaisuke/OpenThai-SystemOne-CoreAI), [APUS Decision](https://huggingface.co/mlboydaisuke/APUS-Decision-v1-4B-CoreAI), decoder/scalar decision heads | Different graph/readout contracts; need another task-specific adapter. |
| [GLiNER2.5 Decide](https://huggingface.co/mlboydaisuke/GLiNER2.5-Decide-CoreAI), [GLiNER2 PII](https://huggingface.co/mlboydaisuke/GLiNER2-PII-CoreAI) | Require span/decision preprocessing and output decoding. |
| [Gemma 4 E2B](https://huggingface.co/mlboydaisuke/gemma-4-E2B-CoreAI), E4B | Static input provider not shipped here. Keep the withdrawn E2B identity blocked, including older installations. |
| [Audio8 TTS](https://huggingface.co/mlboydaisuke/Audio8-TTS-Preview-0.6b-CoreAI), new ASR/speech families | Dedicated audio pipelines and task validation are required; cannot be added as chat. |
| [SoreGus Qwen3 1.7B](https://huggingface.co/SoreGus/Qwen3-1.7B-CoreAI) and similar conversions | Complete artifacts do not prove device parity. Prefer the selected pack with phone verification. |
| Large 27B+ dense and large MoE ports | Mac-sized weights and specialization peaks; exclude from the phone list. |
| `coreai-community` mirrors | Avoid duplicate downloads; use canonical pinned conversions. |

## Validation and release limits

The host tests, catalog invariants, all 35 download checks and device SDK
compile gate pass. The local MatchRater test exercises actual Mac CPU Core ML
inference. It does not replace physical-phone Core AI validation.

Device release checks remain download/install, tokenizer/output parity,
chat/tool templates, memory admission, thermal refusal, cancellation,
background drain/unload, and compiled H18p compatibility. No pack is promoted
automatically merely because an `.aimodel` exists.
