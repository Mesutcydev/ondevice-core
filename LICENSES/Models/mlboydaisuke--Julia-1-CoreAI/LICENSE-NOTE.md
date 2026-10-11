# License and changes

Supersonic Labs declares Apache-2.0 for `SupersonicLabs/Julia-1` in the upstream model card at the pinned revision
`a85b127321d580d65176c89ced8273f305745d85` ("The model artifacts are licensed under Apache 2.0"); no standalone LICENSE or NOTICE file is
listed at that revision. The standard Apache-2.0 text is included as `LICENSE`. The upstream base encoder is
`jhu-clsp/mmBERT-small` (MIT).

Changes relative to the upstream checkpoint:
- re-authored as a static Core AI graph from the raw weights (no transformers or `julia` package code in the
  graph), batch 1, one function `main` (encoder, type embedding, the two head layers and the scorer at every
  position); the checkpoint's `act_head` and `temperature` buffer, which the upstream inference API does not
  read, are not exported;
- `fp32` folders keep the weights as published (F32); `wfp16` folders store them in fp16 (rounded) and
  compute in fp32;
- `tokenizer/` holds the checkpoint's `tokenizer.json` and `tokenizer_config.json`, unmodified;
  `config.json` (the upstream `encoder/config.json`) and `julia_config.json` are the checkpoint's own files,
  unmodified.
Source: `SupersonicLabs/Julia-1@a85b127321d580d65176c89ced8273f305745d85`.
