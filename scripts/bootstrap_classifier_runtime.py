"""Reproduce the pinned llama.cpp runtime, including its missing iOS Simulator slice.

Run once before opening/building this app in Xcode. Downloads are checksum
verified; all native artifacts and downloaded source stay in ignored folders.
Requires Xcode, CMake and an Apple silicon Mac. No model weights are downloaded.
"""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tarfile
import urllib.request
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMIT = "c83f3058b6f876f2f7e6ccbada858b2446860c85"
VERSION = "b11558"
BINARY_SHA256 = "9b56414ddabdae9d82c5bab9cfb2ed506bcd36f85f2c7ee6d5b73be7fb3f6162"
SOURCE_SHA256 = "39ad836834e31ab1a765ed27527b2272941fa38bd502894d58fbc82ac0ddf6a6"
BOOTSTRAP_FORMAT = 4
CACHE = ROOT / "build/ClassifierNative/cache"
DEST = ROOT / "build/ClassifierNative/llama.xcframework"
STAMP = DEST.parent / "runtime-version.json"


def fetch(name, url, checksum):
    target = CACHE / name
    if not target.exists():
        urllib.request.urlretrieve(url, target)
    if hashlib.file_digest(target.open("rb"), "sha256").hexdigest() != checksum:
        raise RuntimeError("Native dependency checksum failed: " + name)
    return target


def run(*arguments):
    subprocess.run(arguments, check=True)


def main():
    with_catalyst = "--with-catalyst" in sys.argv[1:]
    if any(argument != "--with-catalyst" for argument in sys.argv[1:]):
        raise SystemExit("usage: bootstrap_classifier_runtime.py [--with-catalyst]")
    if DEST.exists() and STAMP.exists() and json.loads(STAMP.read_text()) == dict(commit=COMMIT, release=VERSION, simulator="arm64 CPU", format=BOOTSTRAP_FORMAT):
        if with_catalyst:
            catalyst()
        print("Pinned llama.cpp runtime is ready.")
        return
    CACHE.mkdir(parents=True, exist_ok=True)
    binary = fetch(f"llama-{VERSION}-xcframework.zip",
                   f"https://github.com/ggml-org/llama.cpp/releases/download/{VERSION}/llama-{VERSION}-xcframework.zip",
                   BINARY_SHA256)
    archive = fetch("llama-" + COMMIT[:8] + ".tar.gz", "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/" + COMMIT,
                    SOURCE_SHA256)
    extracted = CACHE / "llama-native"
    run("ditto", "-x", "-k", str(binary), str(extracted))
    source = CACHE / ("llama.cpp-" + COMMIT)
    if not source.exists():
        with tarfile.open(archive) as bundle:
            bundle.extractall(CACHE, filter="data")
    build = CACHE / "llama-simulator"
    run("cmake", "-S", str(source), "-B", str(build), "-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_SYSROOT=iphonesimulator",
        "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF", "-DLLAMA_BUILD_COMMON=OFF", "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF",
        "-DLLAMA_BUILD_TOOLS=OFF", "-DLLAMA_BUILD_SERVER=OFF", "-DLLAMA_BUILD_APP=OFF", "-DLLAMA_BUILD_MTMD=ON", "-DGGML_METAL=OFF", "-DGGML_ACCELERATE=ON", "-DGGML_OPENMP=OFF")
    run("cmake", "--build", str(build), "--target", "llama", "mtmd", "--config", "Release", "-j", str(min(8, os.cpu_count() or 4)))
    static = build / "libllama-simulator.a"
    libraries = [p for p in build.rglob("*.a") if p != static]
    run("xcrun", "libtool", "-static", "-o", str(static), *(str(p) for p in libraries))
    headers = build / "Headers"
    headers.mkdir(exist_ok=True)
    for folder in [source / "include", source / "ggml/include", source / "tools/mtmd"]:
        for item in folder.glob("*.h"):
            shutil.copy2(item, headers / item.name)
    simulator = build / "llama.framework"
    simulator.mkdir(exist_ok=True)
    shutil.copy2(static, simulator / "llama")
    shutil.copytree(headers, simulator / "Headers", dirs_exist_ok=True)
    (simulator / "Modules").mkdir(exist_ok=True)
    (simulator / "Modules/module.modulemap").write_text('framework module llama { header "llama.h"\n export *\n}\n')
    (simulator / "Info.plist").write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier="org.ggml.llama", CFBundleName="llama", CFBundleExecutable="llama", CFBundlePackageType="FMWK",
        CFBundleVersion="1", CFBundleShortVersionString="0.6.0", MinimumOSVersion="17.0", CFBundleSupportedPlatforms=["iPhoneSimulator"])))
    framework = extracted / "build-apple/llama.xcframework"
    stage = DEST.parent / "llama-staging.xcframework"
    if stage.exists():
        shutil.rmtree(stage)
    DEST.parent.mkdir(parents=True, exist_ok=True)
    run("xcodebuild", "-create-xcframework",
        "-framework", str(framework / "ios-arm64/llama.framework"),
        "-debug-symbols", str(framework / "ios-arm64/dSYMs/llama.dSYM"),
        "-framework", str(framework / "macos-arm64_x86_64/llama.framework"),
        "-debug-symbols", str(framework / "macos-arm64_x86_64/dSYMs/llama.dSYM"),
        "-framework", str(simulator), "-output", str(stage))
    if DEST.exists():
        shutil.rmtree(DEST)
    stage.rename(DEST)
    STAMP.write_text(json.dumps(dict(commit=COMMIT, release=VERSION, simulator="arm64 CPU", format=BOOTSTRAP_FORMAT), indent=2))
    print("Pinned llama.cpp runtime is ready: " + str(DEST))
    if with_catalyst:
        catalyst()


def catalyst():
    if (DEST / "ios-arm64-maccatalyst").exists():
        return
    environment = dict(os.environ, NATIVE_SOURCE_ROOT=str(CACHE / ("llama.cpp-" + COMMIT)), NATIVE_XCFRAMEWORK=str(DEST))
    subprocess.run(["bash", str(ROOT / "scripts/native/build_catalyst_slice.sh"), "llama"], env=environment, check=True)


if __name__ == "__main__":
    main()
