# Models design studies

Three standalone SwiftUI alternatives, built and rendered on iPhone Simulator.
These use sample data and do not connect to model services, download files, or
change the production Models screen.

- **Dashboard** — dark workspace, current assistant, memory meter, storage,
  runtime count, and role tiles.
- **Apple** — native large navigation title, grouped library, SF Symbols,
  system search and disclosure rows.
- **ChatGPT-inspired** — monochrome chooser, direct selection, short capability
  descriptions, category menu and bottom search.

The study source is outside the application target. Build it as a standalone
SwiftUI app with `ModelsConceptsApp` as the entry point. Launch with `dashboard`,
`apple`, or `chatgpt` as a process argument. Add `large` to preview accessibility
text size. Sample controls only change temporary preview state; Import explains
where the existing document picker will connect after a design is selected.

The model names, sizes, memory values, and statuses are illustrative. They are
not device measurements or a compatibility recommendation. No model weights,
third-party artwork, or new dependencies are included.

## Combined direction

**04 — Dashboard + Apple** (`hybrid` launch argument) combines one active-model
overview and a compact statistics strip with native iOS navigation, grouped
model rows, category filtering, search, and detail sheets. Add `dark` for the
dark appearance. This remains a sample-data study, outside the app target.

**05 — Dashboard + ChatGPT** (`workspace` launch argument) is the corrected
combination requested by the user: one active-model overview, unboxed storage
statistics, an open model chooser, and bottom search. Add `dark` for its dark
appearance. The earlier Dashboard + Apple study is retained as a reference.
