# Classifier print integration — October 16, 2026

The owner requested integrating `/Users/m/Desktop/class` into OnDevice Max's
existing Classifiers page, preserving the result-print animation and fitting
the surrounding controls to OnDevice Max's design language.

The owner-supplied procedural machine and receipt are adapted under
`IOSLocalLLM/Views/Classifiers/`. No binary assets, third-party fonts, model
weights, provider credentials or standalone runtime loaders are copied.

## Motion and presentation

- The machine keeps its 160 × 140 grid, graphite/copper materials, mouth at
  97/140 of its height, and mouth width of 108/160.
- The ticket overlaps the body below the mouth, is masked above the slot and
  feeds with the original spring: response 0.75, damping fraction 0.86.
- Sway keyframes retain the original angles and durations: 0°/0.45 s,
  2.4°/0.3 s, −1.5°/0.35 s, 0.6°/0.35 s and 0°/0.5 s.
- Five rigid print haptics use intensity 0.5 and 80 ms spacing. Numbers count
  up over 0.8 s after a 0.3 s delay. Runner-up rows retain their 0.25 s fade
  and 0.45 + index × 0.07 s delay.
- Reduce Motion replaces paper travel with a fade and disables scanning,
  blinking, sway, number animation and print haptics. Hidden workspaces pause
  scanning/blinking and cancel print tasks. Returning to a printed ticket does
  not restart its haptics or count-up.

All surrounding text, inputs, navigation and buttons use `ODPalette`, `ODLayout`,
the native two-line app-menu control, standard system typography and the ink
glass primary action. The task editor, saved tasks and result inspector use
native sheets. The Classifiers page owns a single `ODWorkspaceBottomBar`,
combining its pinned action with the existing minimized voice accessory.

## State and execution

`CoreAIClassifierWorkbench` still calls the existing shared backend through the
host's exclusive-operation gate. Model admission, cancellation, background
cleanup and runtime residency stay with the established host services.

Each successful run captures an immutable `ClassifierPrintedResult`: a new
identity, the model actually used, typed answer and measured elapsed time.
Identical repeated outputs still print as new runs. Editing a draft retains the
previous ticket with a stale mark; its inspector and JSON export use the
completed run's model and scores. Canceled/failed runs cannot print late output.
No new input or result persistence is introduced.

For yes/no results, a False ticket displays `1 − P(True)` as its confidence.
Score results display the expected rubric index without a percent sign. Image
classifiers retain fixed labels and the existing bounded photo/file importer.

## Source snapshot

SHA-256 of the owner-supplied source read on October 16, 2026, relative to
`/Users/m/Desktop/class/App/Sources/App`:

| Source | SHA-256 |
| --- | --- |
| `Design/Machine.swift` | `dfbbc996547d758a4481f6d54655364ea4cd6f0779a35e08921c0a2bcf48e492` |
| `Design/Ticket.swift` | `21fc0695fa5f6d853ec65250e14e55e2547dadd50bcd30f5c91c4ff6c32057ce` |
| `Classify/ClassifyView.swift` | `17e45f21a285c5f5fa6c147362ad0f2b21673c04822e496164134adfef736cbd` |
| `Design/Tokens.swift` | `94fe618a204dd8fcb8b634957f18cd3ca939b32dc1550db66be5a82b615bd734` |
| `Design/BrandComponents.swift` | `2b3ea657ebcd18f8a174819315a11763139854eeebecfd6ab4a3957abd860809` |

The ticket and machine translations are adapted from the same owner's
`App/Resources/Localizable.xcstrings`, SHA-256
`9f4e47cace0fa60a768de1483e4d7d4c65743c4536586c9289f8ae86b8669fea`.
New controls and ticket labels are registered in the shared OnDeviceUI catalog
with all six shipped UI translations.

## Verification

The Foundation classifier suite passed all 43 tests, including fresh print
identities, completed-model snapshots, stale drafts and cancellation. The
NativeUI host compiles the production machine, ticket and controls; all four
print contracts passed, covering Choice/Score/Yes-No semantics and explicit
English/German number formatting. The open-source validator passed, including
the shared catalog's six UI translations.

Native simulator interaction verified activation, Choice printing and identical
reprints, Score and Yes/No results, image input, ticket inspection and the JSON
export action. It also exposed an oversized accessibility frame from the
source's clipped text leaders; bounded Canvas leaders preserve the dots while
keeping the ticket's button frame inside the screen. Score numbers now use the
app's selected locale consistently with the inspector.

The automated UI flows compile, but the simulator UI-test launcher stalled;
those flows are not recorded as passing. Simulator scores are fixtures, not
physical-device inference evidence. The real application's unsigned generic
iOS build-for-testing compile gate also passed. The local preview and native
interaction evidence are in the ignored `build/classifier-print-evidence/`.
