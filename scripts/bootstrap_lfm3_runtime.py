#!/usr/bin/env python3
"""Prepare the experimental LFM3 runtime without replacing the shipping one."""
import json
import sys

import bootstrap_classifier_runtime as native

native.COMMIT = "19cce6919992fdffd92e0ac152caaf1e2b8f254e"
native.VERSION = "b11938"
native.BINARY_SHA256 = "524054f89b3c26a71ef0230be1193a7fc07a1fd439f163df7a4b8df9c776df96"
native.SOURCE_SHA256 = "e16c6d1076af7a2bdb351e22176dd4b302f244ac4c3822604e2ec64a8a783d44"
native.CACHE = native.ROOT / "build/LFM3Native/cache"
native.DEST = native.ROOT / "build/LFM3Native/llama.xcframework"
native.STAMP = native.DEST.parent / "runtime-version.json"


def ready():
    expected = dict(commit=native.COMMIT, release=native.VERSION, simulator="arm64 CPU", format=native.BOOTSTRAP_FORMAT)
    source = native.CACHE / ("llama.cpp-" + native.COMMIT)
    try:
        return (native.DEST.is_dir() and json.loads(native.STAMP.read_text()) == expected
                and (source / "include/llama.h").is_file()
                and (source / "tools/mtmd/mtmd.h").is_file())
    except (OSError, ValueError):
        return False


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        if not ready():
            raise SystemExit("LFM3 runtime is not ready. Run python3 scripts/bootstrap_lfm3_runtime.py first.")
        print("Experimental LFM3 runtime is ready.")
    else:
        native.main()
