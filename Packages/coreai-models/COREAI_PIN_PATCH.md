# coreai-models (OnDevice Max AI Studio pin)

Vendored from https://github.com/apple/coreai-models.git
at revision `938d0b8943b942ce66438b94ab017c5631d1aef4`.

## Local patch

`swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift`
constructs `LanguageModelCapabilities` through the **unlabeled** `init(_:)`
instead of upstream's `init(capabilities:)`.

**Why:** in the Xcode 27 SDK the labeled initializer is declared
`@available(*, deprecated, renamed: "init(_:)")`. Both spellings are listed in
`FoundationModels.tbd`, so linking succeeds, but iPhone OS 27.0 builds no longer
export the deprecated symbol from the shipping framework binary. `dyld` then
aborts the process at load:

```
dyld: Symbol not found: _$s16FoundationModels25LanguageModelCapabilities
                        V12capabilitiesACSayAC10CapabilityVG_tcfC
  Expected in: /System/Library/Frameworks/FoundationModels.framework/FoundationModels
```

That happens **before `main`**, so there is no crash log and the in-app
`CrashReporter` never installs — the app simply bounces on launch.

Guard: `scripts/verify_foundationmodels_symbols.sh <Release.app>` fails on this
class of import. Run it before packaging any IPA.

## Corrected history

An earlier note in this file claimed the pin existed because
`LanguageModelExecutorGenerationChannel.Response.Action.updateUsage` was missing
from the device binary. That was wrong for this SDK: all 214
`LanguageModelExecutorGenerationChannel` symbols are present in
`FoundationModels.tbd`, and the app's 110 imported FoundationModels symbols all
resolve. `init(capabilities:)` was the actual cause. The upstream
`.updateUsage(...)` call remains removed in this vendored copy, but that is now
an unrelated leftover rather than the reason for the pin.

Remove this pin and return to the remote package once upstream adopts the
renamed initializer.

## Hybrid-state backport

The runtime also backports Apple commit
`632941266b6f11ed7ac4f63f74a607fb75621853` (hybrid model state handlers).
This allows models such as LFM2.5 that expose a persistent convolution state
in addition to their key/value caches to load and reset correctly in both the
sequential and pipelined engines. Keep this backport until the package pin can
be removed.

The pipelined backport also carries local fixed-shape safety in
`StateHandler+MTLBuffer.swift`: fixed hybrid descriptors are used directly for
their byte count and strides.

## Decode-only S=1 support

The LFM2.5 bundles are decode-only graphs whose token and logits sequence
dimensions are fixed at one. `CoreAIPipelinedEngine` therefore mirrors the
model zoo's `coreai-pipelined-extra-states.patch` behavior: it allocates the
logits buffer at the descriptor's fixed sequence length, prefills with S=1
steps, and restricts warmup to S=1. Without those guards the engine attempts a
256-token substitution and CoreAIRuntime terminates the process with SIGTRAP
instead of returning a Swift error.

The reference behavior was verified against
`john-rocky/coreai-model-zoo@f85178aeeacf1883797fec38cdb22b51c17b4618`.
Keep the shape-policy regression coverage in `StateHandlerTests` until the
vendored Apple runtime contains equivalent fixed-S=1 handling.

## Chat template and streaming text fixes

`CoreAILanguageModel.CoreAIExecutor.makeTokens` now treats an empty result from
`applyChatTemplate` as a failure and falls back to role-labelled text encoding.
Previously it handed an empty token array to FoundationModels, which rejected
the prompt as unsupported transcript content even when the latest user turn
was ordinary text.

`CoreAIStreamingTokenDecoder` replaces the two-token decoding window. The old
window assumed a token decoded alone remained a prefix when the next token
arrived; that assumption can drop spaces or repeat text for some tokenizers.
The new decoder compares complete generated prefixes, holds unstable text
until the next token, and discards unknown-token placeholders. The focused
tests live in `CoreAIStreamingTokenDecoderTests.swift`. These patches should
be reviewed when updating the upstream pin.
