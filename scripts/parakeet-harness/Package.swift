// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "harness",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.19.2")],
    targets: [.executableTarget(name: "harness",
        dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
        path: "Sources/harness")]
)
