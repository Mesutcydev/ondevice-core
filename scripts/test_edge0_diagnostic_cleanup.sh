#!/usr/bin/env bash
# Run the diagnostic cleanup barrier tests without weights or CoreAI.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf "$test_directory"' EXIT
mkdir -p "$test_directory/Sources/IOSLocalLLM" "$test_directory/Tests/DiagnosticTests"
cp "$repository_root/IOSLocalLLM/Services/Runtime/Edge0/Edge0DiagnosticPreferences.swift" \
    "$repository_root/IOSLocalLLM/Services/Runtime/Edge0/Edge0EnginePreferences.swift" \
    "$test_directory/Sources/IOSLocalLLM/"
cp "$repository_root/IOSLocalLLMTests/Edge0DiagnosticPreferencesTests.swift" \
    "$test_directory/Tests/DiagnosticTests/"
# Reuse the production enum declarations while excluding their MLX-dependent
# neighbors. Only the engine's unrelated default-mode provider is stubbed.
python3 - "$repository_root" "$test_directory" <<'PY'
import re
import sys
from pathlib import Path
root, work = map(Path, sys.argv[1:])
runtime = root / "IOSLocalLLM/Services/Runtime/Edge0"
declarations = ["import Foundation"]
for name, filename in (
    ("Edge0ExecutionMode", "Edge0Model.swift"),
    ("Edge0_35BPoolAccounting", "Edge0_35BMemoryBudget.swift"),
):
    source = (runtime / filename).read_text()
    match = re.search(rf"^enum {name}\b[^{{]*{{.*?^}}", source, re.M | re.S)
    if match is None:
        raise SystemExit(f"missing production declaration: {name}")
    declarations.append(match.group())
declarations.append("enum Edge0_35BEngine { static let defaultExecutionMode: Edge0ExecutionMode = .staged }")
(work / "Sources/IOSLocalLLM/HostTypes.swift").write_text("\n\n".join(declarations))
PY
cat > "$test_directory/Package.swift" <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "DiagnosticChecks", platforms: [.macOS(.v13)], targets: [
    .target(name: "IOSLocalLLM"),
    .testTarget(name: "DiagnosticTests", dependencies: ["IOSLocalLLM"])
])
SWIFT
CLANG_MODULE_CACHE_PATH="$test_directory/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$test_directory/ModuleCache" \
    swift test --package-path "$test_directory" --disable-sandbox \
    --cache-path "$test_directory/cache" --config-path "$test_directory/config" \
    --security-path "$test_directory/security"
