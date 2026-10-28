# Notices

## This repository

Core ML conversion of the laya-multilingual decision model, by Fluid Inference.
Licensed under the Apache License, Version 2.0; see `LICENSE`.

## Upstream model and code

The converted weights and the reference implementation are the work of
Convai Innovations and contributors, used under the Apache License, Version 2.0.

- Weights: [`convaiinnovations/laya`](https://huggingface.co/convaiinnovations/laya),
  subfolder `multilingual`, revision `1c5edc17a7acd8701df6fc341c0d179f1c62c982`.
- Reference implementation: [`NandhaKishorM/laya`](https://github.com/NandhaKishorM/laya).

The encoder is [`jhu-clsp/mmBERT-base`](https://huggingface.co/jhu-clsp/mmBERT-base),
and `tokenizer.json` carries its vocabulary, redistributed under that model's terms.

No weights were retrained. The conversion changes tensor precision and fixes input
shapes; the parameters are the upstream ones. This is an independent conversion and
is not an official Convai Innovations release.
