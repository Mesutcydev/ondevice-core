#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p test_edge0_repack.py
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0Safetensors.swift \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0TensorStore.swift \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0ModelFamily.swift \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0_35BRepackedExperts.swift \
  scripts/tests/Edge0RepackedChecks.swift -o "$test_dir/checks"
"$test_dir/checks"
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0Safetensors.swift \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0TensorStore.swift \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0ModelFamily.swift \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0_35BModelConfiguration.swift \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0_35BModelArtifacts.swift \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0_35BRepackedExperts.swift \
  IOSLocalLLM/Services/Runtime/Edge0/Edge0_35BRepacker.swift \
  scripts/tests/Edge0RepackerChecks.swift -o "$test_dir/repacker-checks"
"$test_dir/repacker-checks"
