#!/usr/bin/env python3
"""Prepare the whisper.cpp v1.9.5 runtime beside the pinned 1.8.4 submodule.

ThirdParty/whisper.cpp (1.8.4) stays untouched. build/WhisperNative mirrors its
layout (include/ and build-apple/whisper.xcframework), so a build selects 1.9.5
with ONDEVICE_WHISPER_ROOT=$PWD/build/WhisperNative and switches back by
dropping that setting; headers and framework always move together.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = "v1.9.5"
COMMIT = "d1be6fde11ac6e0407606b4e42fe72d34add8037"
DEST = ROOT / "build/WhisperNative"
SOURCE = DEST / "cache" / f"whisper.cpp-{COMMIT}"
FRAMEWORK = DEST / "build-apple/whisper.xcframework"
STAMP = DEST / "runtime-version.json"


def ready():
    try:
        stamp = json.loads(STAMP.read_text())
    except (OSError, ValueError):
        return False
    return stamp.get("commit") == COMMIT and FRAMEWORK.is_dir() and (DEST / "include/whisper.h").is_file()


def run(*args, **kwargs):
    print("==>", " ".join(str(a) for a in args), flush=True)
    subprocess.run(args, check=True, **kwargs)


def main():
    if ready():
        print(f"whisper.cpp {VERSION} runtime is already prepared in {DEST}")
        return
    if FRAMEWORK.exists():
        raise SystemExit(f"{FRAMEWORK} exists without a matching stamp; remove build/WhisperNative and retry.")
    if not SOURCE.exists():
        run("git", "clone", "--depth", "1", "--branch", VERSION,
            "https://github.com/ggml-org/whisper.cpp.git", SOURCE)
    head = subprocess.run(["git", "-C", SOURCE, "rev-parse", "HEAD"],
                          check=True, capture_output=True, text=True).stdout.strip()
    if head != COMMIT:
        raise SystemExit(f"{VERSION} resolved to {head}, expected {COMMIT}")

    env = {**os.environ, "NATIVE_SOURCE_ROOT": str(SOURCE)}
    run(ROOT / "scripts/native/build_whisper_ios.sh", env=env)
    run(ROOT / "scripts/native/build_catalyst_slice.sh", "whisper",
        env={**env, "NATIVE_XCFRAMEWORK": str(SOURCE / "build-apple/whisper.xcframework")})

    FRAMEWORK.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(SOURCE / "build-apple/whisper.xcframework", FRAMEWORK)
    shutil.copytree(SOURCE / "include", DEST / "include", dirs_exist_ok=True)
    shutil.copy2(SOURCE / "LICENSE", DEST / "LICENSE")
    # The intermediate builds are a few GB; the framework and headers are all a build needs.
    for build_dir in ("build-ios-sim", "build-ios-device", "build-maccatalyst", "build-apple"):
        shutil.rmtree(SOURCE / build_dir, ignore_errors=True)
    STAMP.write_text(json.dumps({"version": VERSION, "commit": COMMIT}, indent=2) + "\n")
    print(f"whisper.cpp {VERSION} runtime is ready: ONDEVICE_WHISPER_ROOT={DEST}")


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        if not ready():
            raise SystemExit("whisper.cpp 1.9.5 runtime is not ready. Run python3 scripts/bootstrap_whisper_runtime.py first.")
        print(f"whisper.cpp {VERSION} runtime is ready.")
    else:
        main()
