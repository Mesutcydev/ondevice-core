// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Mac checks for the app's ONNX speech engines, on the app's own ONNX Runtime:
// the CocoaPods onnxruntime-c xcframework (it has a macOS slice) and the
// onnxruntime-objc wrapper sources, both reached through symlinks into Pods/
// (run `pod install` first). Each engine file is the app's, symlinked.
//   swift run -c release supertonic selftest | <model dir> <out dir>
//   swift run -c release parakeet <model dir> <16 kHz .wav>...
//   swift run -c release nemotron <model dir> <lang>=<16 kHz .wav>...
let ortHeaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Pods/onnxruntime-c/Headers").standardized.path

let package = Package(
    name: "onnx-harness",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "onnxruntime", path: "onnxruntime.xcframework"),
        .target(name: "OnnxRuntimeBindings", dependencies: ["onnxruntime"], path: "Sources/OnnxRuntimeBindings",
                publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-I", ortHeaders])],
                linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Foundation"),
                                 .linkedFramework("CoreML"), .linkedFramework("Network")]),
        .executableTarget(name: "supertonic", dependencies: ["OnnxRuntimeBindings"], path: "Sources/supertonic"),
        .executableTarget(name: "parakeet", dependencies: ["OnnxRuntimeBindings"], path: "Sources/parakeet"),
        .executableTarget(name: "nemotron", dependencies: ["OnnxRuntimeBindings"], path: "Sources/nemotron"),
    ],
    cxxLanguageStandard: .cxx17
)
