#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/module-cache" \
  IOSLocalLLM/Services/ModelMemoryBudget.swift scripts/tests/MemoryBudgetChecks.swift \
  -o "$test_dir/checks"
"$test_dir/checks"
