// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnDeviceUI",
    platforms: [.iOS("26.0")],
    products: [.library(name: "OnDeviceUI", targets: ["OnDeviceUI"])],
    targets: [
        .target(name: "OnDeviceUI", resources: [.process("Resources")]),
        .testTarget(name: "OnDeviceUITests", dependencies: ["OnDeviceUI"])
    ]
)
