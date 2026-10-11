# License and changes

Convai Innovations declares Apache-2.0 for `convaiinnovations/laya` in the upstream model card at the pinned revision
`1c5edc17a7acd8701df6fc341c0d179f1c62c982`; no standalone LICENSE or NOTICE file is listed at that revision. The unmodified upstream card
(`UPSTREAM_README.md`) and the standard Apache-2.0 text (`LICENSE`) are included.

Changes relative to the upstream `multilingual/` checkpoint:
- re-authored as a static Core AI graph from the raw weights (no transformers or laya code in the graph),
  windows 256 and 512, batch 1;
- one bundle with two functions: `main` (encoder, type embedding, the two head layers and the scorer at every
  position, plus the first position's hidden state) and `act` (the act head, fp32);
- `wfp16` folders store the weights in fp16 (exact: the checkpoint is stored in F16) and compute in fp32;
  `fp32` folders are the reference; `ios-h18p/` holds an iPhone 17 Pro (h18p) GPU compile of the wfp16 bundle;
- `metadata.json` carries the checkpoint's temperatures (T = 1) and, beside them, the fitted calibration
  published with litert-community/Laya-Multilingual-LiteRT (`laya_ml_calibration.json`);
- `tokenizer/` holds the checkpoint's `tokenizer.json` and `tokenizer_config.json`, unmodified;
  `config.json` and `rl_agent_config.json` are the checkpoint's own files, unmodified.
Source: `convaiinnovations/laya@1c5edc17a7acd8701df6fc341c0d179f1c62c982`, subfolder `multilingual`.
