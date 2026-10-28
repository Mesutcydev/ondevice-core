#!/usr/bin/env bash
set -euo pipefail
cleanup_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup_work="$(mktemp -d)"
trap 'rm -rf "$cleanup_work"' EXIT
mkdir -p "$cleanup_work/Sources/IOSLocalLLM" "$cleanup_work/Tests/CleanupTests"
cp "$cleanup_root/IOSLocalLLM/Services/BackgroundDownloadCoordinator.swift" "$cleanup_work/Sources/IOSLocalLLM/"
cp "$cleanup_root/IOSLocalLLMTests/BackgroundDownloadCoordinatorTests.swift" "$cleanup_work/Tests/CleanupTests/"
cat > "$cleanup_work/Sources/IOSLocalLLM/HostServices.swift" <<'SWIFT'
import Foundation
@MainActor final class AppSettings { static let shared = AppSettings(); var wifiOnlyDownloads = false }
enum HFTokenStore { static func authorize(_ request: inout URLRequest) {} }
final class Diagnostics { static let shared = Diagnostics()
    func error(_ value: String, category: String) {}
    func breadcrumb(_ value: String, category: String) {}
}
extension FileManager { static func excludeFromBackup(_ url: URL) {} }
@MainActor final class DownloadLiveActivityManager {
    enum Phase { case downloading, verifying, preparing }
    static let shared = DownloadLiveActivityManager()
    func start(repoID: String, displayName: String? = nil) -> Bool { false }
    func update(repoID: String, progress: Double, downloadedBytes: Int64, totalBytes: Int64,
                currentFile: String, filesDone: Int, filesTotal: Int, phase: Phase = .downloading) {}
    func finish(repoID: String) {}
    func pause(repoID: String) {}
    func cancel(repoID: String) {}
    func fail(repoID: String, reason: String) {}
}
SWIFT
cp "$cleanup_root/IOSLocalLLM/Services/BackgroundDownloadJournal.swift" "$cleanup_work/Sources/IOSLocalLLM/"
cp "$cleanup_root/IOSLocalLLM/Services/HFDownloadScope.swift" "$cleanup_work/Sources/IOSLocalLLM/"
cp "$cleanup_root/IOSLocalLLMTests/BackgroundDownloadJournalTests.swift" "$cleanup_work/Tests/CleanupTests/"
cp "$cleanup_root/IOSLocalLLMTests/HFDownloadScopeTests.swift" "$cleanup_work/Tests/CleanupTests/"
cat > "$cleanup_work/Package.swift" <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "DownloadCleanupChecks", platforms: [.macOS(.v14)], targets: [
    .target(name: "IOSLocalLLM"),
    .testTarget(name: "CleanupTests", dependencies: ["IOSLocalLLM"])
])
SWIFT
CLANG_MODULE_CACHE_PATH="$cleanup_work/module-cache" SWIFT_MODULE_CACHE_PATH="$cleanup_work/module-cache" \
swift test --package-path "$cleanup_work" --scratch-path "$cleanup_work/.build" \
    --cache-path "$cleanup_work/cache" --config-path "$cleanup_work/config" \
    --security-path "$cleanup_work/security" --disable-sandbox
