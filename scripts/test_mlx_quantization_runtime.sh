#!/usr/bin/env bash
# Synthetic kernel/compatibility checks on an Apple Silicon Mac. No weights.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence_directory="${1:-$repository_root/build/mlx-quantization-runtime}"
mkdir -p "$evidence_directory"
evidence_directory="$(cd "$evidence_directory" && pwd)"
source_packages="${2:-$evidence_directory/SourcePackages}"
python3 - "$repository_root" "$evidence_directory" <<'PY'
from pathlib import Path
import re
import sys
root, work = map(Path, sys.argv[1:])
project = (root / 'project.yml').read_text()
core = re.search(r'  mlx-swift:\n.*?revision: ([0-9a-f]{40})', project, re.S).group(1)
version = re.search(r'  mlx-swift-lm:\n.*?exactVersion: "([^"]+)"', project, re.S).group(1)
(work / 'project.yml').write_text(f'''name: MLXQuantizationChecks
packages:
  mlx-swift:
    url: https://github.com/PrismML-Eng/mlx-swift.git
    revision: {core}
  mlx-swift-lm:
    url: https://github.com/ml-explore/mlx-swift-lm
    exactVersion: "{version}"
targets:
  MLXQuantizationChecks:
    type: tool
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: "{root / 'scripts/tests/MLXQuantizationRuntimeChecks.swift'}"
    dependencies:
      - package: mlx-swift
        product: MLX
      - package: mlx-swift-lm
        product: MLXLMCommon
    settings:
      base:
        CODE_SIGNING_ALLOWED: NO
        SWIFT_VERSION: "5.10"
        ARCHS: arm64
schemes:
  MLXQuantizationChecks:
    build:
      targets:
        MLXQuantizationChecks: all
''')
PY
xcodegen generate --spec "$evidence_directory/project.yml"
lock_directory="$evidence_directory/MLXQuantizationChecks.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$lock_directory"
cp "$repository_root/TokenAI.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
   "$lock_directory/Package.resolved"
xcodebuild build -project "$evidence_directory/MLXQuantizationChecks.xcodeproj" \
    -scheme MLXQuantizationChecks -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$evidence_directory/DerivedData" \
    -clonedSourcePackagesDirPath "$source_packages" -skipPackageUpdates \
    -onlyUsePackageVersionsFromResolvedFile -jobs 4 CODE_SIGNING_ALLOWED=NO \
    > "$evidence_directory/build.log" 2>&1
"$evidence_directory/DerivedData/Build/Products/Debug/MLXQuantizationChecks"
