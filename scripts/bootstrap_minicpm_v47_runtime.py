#!/usr/bin/env python3
"""Build a private, namespaced MiniCPM LES runtime; never replace llama.xcframework."""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REVISION = "0b74404c9b3dfe2c6b11aebe0dd58fc23f133ee2"
ARCHIVE_SHA256 = "5dcdd70ce6f9d583eac0f1b142311cb1d057ba83729fd581ecff692ee19436c9"
DEST = ROOT / "build/MiniCPMNative"
CACHE = DEST / "cache"


def run(*args):
    subprocess.run(args, check=True)


def patch_context_rebuild(source):
    # Original shim for this exact runtime pin. Expert storage belongs to the
    # model, while its parked flag belongs to the old context. Rewrap that
    # storage before replacing the context; keep ordinary unload parking intact.
    edits = {
        "include/llama.h": (
            "    LLAMA_API void llama_moe_park_expert_memory(struct llama_context * ctx);",
            "    LLAMA_API void llama_moe_park_expert_memory(struct llama_context * ctx);\n"
            "    LLAMA_API bool llama_moe_unpark_for_context_rebuild(struct llama_context * ctx);"),
        "src/llama-context.h": (
            "    void park_moe_expert_memory();",
            "    void park_moe_expert_memory();\n    bool unpark_moe_for_context_rebuild();"),
        "src/llama-context.cpp": (
            "void llama_context::park_moe_expert_memory() {",
            "bool llama_context::unpark_moe_for_context_rebuild() {\n"
            "    if (!moe_slots) return true;\n    synchronize();\n"
            "    try { moe_slots->ensure_unparked(); return true; }\n"
            "    catch (...) { return false; }\n}\n\n"
            "bool llama_moe_unpark_for_context_rebuild(llama_context * ctx) {\n"
            "    return ctx && ctx->unpark_moe_for_context_rebuild();\n}\n\n"
            "void llama_context::park_moe_expert_memory() {"),
    }
    for name, (before, after) in edits.items():
        path = source / name
        content = path.read_text()
        if after in content:
            continue
        if content.count(before) != 1:
            raise SystemExit("Unexpected pinned MiniCPM context source: " + name)
        path.write_text(content.replace(before, after))


def patch_numeric_counters(source):
    # Read existing atomic counters without enabling stderr probes, adding
    # synchronization or exposing any upstream symbol from our framework.
    edits = {
        "include/llama.h": (
            "    LLAMA_API bool llama_moe_unpark_for_context_rebuild(struct llama_context * ctx);",
            "    LLAMA_API bool llama_moe_unpark_for_context_rebuild(struct llama_context * ctx);\n"
            "    LLAMA_API bool llama_moe_counters_snapshot(struct llama_context * ctx, int64_t * values, size_t count);"),
        "src/llama-context.h": (
            "    bool unpark_moe_for_context_rebuild();",
            "    bool unpark_moe_for_context_rebuild();\n"
            "    bool moe_counters_snapshot(int64_t * values, size_t count) const;"),
        "src/llama-context.cpp": (
            "bool llama_context::unpark_moe_for_context_rebuild() {",
            "bool llama_context::moe_counters_snapshot(int64_t * values, size_t count) const {\n"
            "    if (!moe_slots || !values || count != 7) return false;\n"
            "    const auto c = moe_slots->counters_snapshot();\n"
            "    values[0] = c.process; values[1] = c.readids; values[2] = c.install;\n"
            "    values[3] = c.writeids; values[4] = c.miss; values[5] = c.bytes;\n"
            "    values[6] = c.unique; return true;\n}\n\n"
            "bool llama_moe_counters_snapshot(llama_context * ctx, int64_t * values, size_t count) {\n"
            "    return ctx && ctx->moe_counters_snapshot(values, count);\n}\n\n"
            "bool llama_context::unpark_moe_for_context_rebuild() {"),
    }
    for name, (before, after) in edits.items():
        path = source / name
        content = path.read_text()
        if after in content:
            continue
        if content.count(before) != 1:
            raise SystemExit("Unexpected pinned MiniCPM counter source: " + name)
        path.write_text(content.replace(before, after))


def main():
    mac_only = "--mac-only" in sys.argv[1:]
    if any(a != "--mac-only" for a in sys.argv[1:]):
        raise SystemExit("usage: bootstrap_minicpm_v47_runtime.py [--mac-only]")
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / "runtime.tar.gz"
    seed = os.environ.get("MINICPM_RUNTIME_ARCHIVE")
    if not archive.exists():
        if seed:
            shutil.copyfile(seed, archive)
        else:
            urllib.request.urlretrieve("https://codeload.github.com/OpenBMB/llama.cpp-omni/tar.gz/" + REVISION, archive)
    with archive.open("rb") as f:
        if hashlib.file_digest(f, "sha256").hexdigest() != ARCHIVE_SHA256:
            raise SystemExit("MiniCPM runtime source checksum mismatch")
    source = CACHE / ("llama.cpp-omni-" + REVISION)
    if not source.exists():
        with tarfile.open(archive) as bundle:
            bundle.extractall(CACHE, filter="data")
    patch_context_rebuild(source)
    patch_numeric_counters(source)
    cmake = source / "CMakeLists.txt"
    marker = "# Token AI isolated MiniCPM adapter"
    original = cmake.read_text().split(marker)[0].rstrip()
    cmake.write_text(original + '\n\n' + marker
        + '\nif(NOT TARGET mtmd)\n add_subdirectory(tools/mtmd od-mtmd)\nendif()\n'
        + 'add_subdirectory("' + str(ROOT / "Native/MiniCPMV47") + '" "od-minicpm")\n')
    slices = [("macos", "macosx", "arm64-apple-macos15.0")]
    if not mac_only:
        slices += [("ios", "iphoneos", "arm64-apple-ios27.0"),
                   ("catalyst", "macosx", "arm64-apple-ios27.0-macabi")]
    frameworks = []
    for name, sdk, triple in slices:
        build = CACHE / ("build-" + name)
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        args = ["cmake", "-S", str(source), "-B", str(build),
                "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
                "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_SYSROOT=" + sdk_path,
                "-DCMAKE_C_COMPILER_TARGET=" + triple, "-DCMAKE_CXX_COMPILER_TARGET=" + triple,
                "-DLLAMA_BUILD_COMMON=OFF", "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF",
                "-DLLAMA_BUILD_TOOLS=OFF", "-DLLAMA_BUILD_MTMD=ON", "-DLLAMA_BUILD_SERVER=OFF",
                "-DGGML_METAL=ON", "-DGGML_METAL_EMBED_LIBRARY=ON", "-DGGML_ACCELERATE=ON", "-DGGML_OPENMP=OFF", "-DMTMD_VIDEO=OFF"]
        if name == "ios":
            args += ["-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0"]
        elif name == "catalyst":
            flags = "-target " + triple + " -isysroot " + sdk_path
            flags += " -iframework " + sdk_path + "/System/iOSSupport/System/Library/Frameworks"
            flags += " -I" + sdk_path + "/System/iOSSupport/usr/include"
            args += ["-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0"]
            args += ["-DCMAKE_" + kind + "_FLAGS=" + flags
                     for kind in ["C", "CXX", "OBJC", "OBJCXX", "ASM", "EXE_LINKER", "SHARED_LINKER"]]
        else:
            args += ["-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0"]
        run(*args)
        run("cmake", "--build", str(build), "--target", "ODMiniCPM", "-j", str(min(6, os.cpu_count() or 4)))
        matches = list(build.rglob("ODMiniCPM.framework"))
        if len(matches) != 1:
            raise SystemExit("Expected exactly one built MiniCPM framework")
        framework = matches[0]
        if not (framework / "Headers/ODMiniCPM.h").is_file():
            raise SystemExit("MiniCPM framework is missing its public C header")
        info_path = framework / "Info.plist"
        if not info_path.is_file():
            info_path = framework / "Resources/Info.plist"
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        minimum_key = "LSMinimumSystemVersion" if name == "macos" else "MinimumOSVersion"
        expected = {"CFBundleExecutable": "ODMiniCPM", "CFBundleName": "ODMiniCPM",
                    "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "1.0.0",
                    "CFBundleVersion": "1", minimum_key: "15.0" if name == "macos" else "27.0"}
        if any(info.get(key) != value for key, value in expected.items()):
            raise SystemExit("MiniCPM framework has invalid distribution metadata: " + name)
        modules = framework / "Modules"
        modules.mkdir(exist_ok=True)
        (modules / "module.modulemap").write_text('framework module ODMiniCPM {\n umbrella header "ODMiniCPM.h"\n export *\n}\n')
        exported = subprocess.check_output(["nm", "-gU", str(framework / "ODMiniCPM")], text=True)
        if " _llama_" in exported or " _ggml_" in exported or " _mtmd_" in exported:
            raise SystemExit("Private runtime symbols escaped the MiniCPM framework")
        frameworks += ["-framework", str(framework)]
    if not mac_only:
        stage = DEST / "ODMiniCPM-staging.xcframework"
        if stage.exists():
            shutil.rmtree(stage)
        run("xcodebuild", "-create-xcframework", *frameworks, "-output", str(stage))
        target = DEST / "ODMiniCPM.xcframework"
        if target.exists():
            shutil.rmtree(target)
        stage.rename(target)
        (DEST / "runtime-version.json").write_text(json.dumps(dict(revision=REVISION, archive_sha256=ARCHIVE_SHA256, format=1), indent=2) + "\n")
    print("MiniCPM LES runtime built with private native symbols.")


if __name__ == "__main__":
    main()
