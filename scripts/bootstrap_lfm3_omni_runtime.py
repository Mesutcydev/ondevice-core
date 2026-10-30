#!/usr/bin/env python3
"""Prepare the llama.cpp b11960 runtime that LFM3-Omni needs, beside the b11938 one.

build/LFM3Native (b11938) stays untouched, so switching a build back is a matter
of pointing ONDEVICE_LLAMA_FRAMEWORK_DIR/ONDEVICE_LLAMA_SOURCE at it again.
"""
import sys

import bootstrap_lfm3_runtime as lfm3

native = lfm3.native
native.COMMIT = "8642541b255bfb5dc39cd351a178be09013a55d6"
native.VERSION = "b11960"
native.BINARY_SHA256 = "feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759"
native.SOURCE_SHA256 = "1688a167a8edd9499cdd0c19b8bd044f0fa184b466981977bbf2222d884953a4"
native.CACHE = native.ROOT / "build/LFM3OmniNative/cache"
native.DEST = native.ROOT / "build/LFM3OmniNative/llama.xcframework"
native.STAMP = native.DEST.parent / "runtime-version.json"


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        if not lfm3.ready():
            raise SystemExit("LFM3-Omni runtime is not ready. Run python3 scripts/bootstrap_lfm3_omni_runtime.py first.")
        print("LFM3-Omni runtime (b11960) is ready.")
    else:
        native.main()
