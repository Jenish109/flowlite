// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowLiteKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FlowLiteCore", targets: ["FlowLiteCore"]),
        .library(name: "FlowLiteSystem", targets: ["FlowLiteSystem"]),
        .executable(name: "flowlite-golden", targets: ["flowlite-golden"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "FlowLiteCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "FlowLiteSystem",
            dependencies: ["FlowLiteCore", .product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .executableTarget(
            name: "flowlite-golden",
            dependencies: ["FlowLiteCore", "FlowLiteSystem", .product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .testTarget(name: "FlowLiteCoreTests", dependencies: ["FlowLiteCore"]),
    ],
    swiftLanguageModes: [.v5]
)
