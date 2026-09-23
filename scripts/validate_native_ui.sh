#!/bin/bash
set -euo pipefail

simulator_id="${1:?Usage: bash scripts/validate_native_ui.sh SIMULATOR_UDID}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

xcodegen generate --spec QA/NativeUI/project.yml
xcodebuild test \
  -collect-test-diagnostics never \
  -project QA/NativeUI/NativeUIReview.xcodeproj \
  -scheme NativeUIReview \
  -parallel-testing-enabled NO \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath build/NativeUIReview/DerivedData \
  CODE_SIGNING_ALLOWED=NO

runner_container="$(xcrun simctl get_app_container "$simulator_id" com.example.OnDeviceNativeUIReview.flows.xctrunner data)"
evidence_directory="$repo_root/build/native-ui-evidence/latest-ui"
mkdir -p "$evidence_directory"
cp "$runner_container/Documents/NativeUIReviewScreenshots/"*.png "$evidence_directory/"

cd "$repo_root/Packages/OnDeviceUI"
xcodebuild test \
  -collect-test-diagnostics never \
  -scheme OnDeviceUI \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath .build/ContractTests \
  CODE_SIGNING_ALLOWED=NO
