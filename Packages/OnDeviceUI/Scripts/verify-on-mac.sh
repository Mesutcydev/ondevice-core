#!/usr/bin/env bash
set -euo pipefail

handoff_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Run this script on a Mac with Xcode 26 or newer and the iOS 26 Simulator SDK installed."
    exit 2
fi

simulator_sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
simulator_sdk_major="${simulator_sdk_version%%.*}"
if ! [[ "$simulator_sdk_major" =~ ^[0-9]+$ ]] || (( simulator_sdk_major < 26 )); then
    echo "This native Liquid Glass package requires the iOS 26 Simulator SDK or newer."
    exit 2
fi

build_output="$handoff_root/.build/Validation"
mkdir -p "$build_output"
xcodebuild \
    -project "$handoff_root/Example/OnDeviceUIDemo.xcodeproj" \
    -scheme OnDeviceUIDemo \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_output/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tee "$build_output/build.log"

echo "Simulator build completed. Open the demo in Xcode and follow Documentation/Validation.md for visual checks."
