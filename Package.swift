// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlipperHero",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FlipperKit", targets: ["FlipperKit"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "FlipperProto",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(name: "FlipperKit", dependencies: ["FlipperProto"], resources: [.process("Resources")]),
        .target(name: "AgentKit", dependencies: ["FlipperKit"], resources: [.process("Resources")]),
        .testTarget(name: "FlipperKitTests", dependencies: ["FlipperKit"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
    ],
    swiftLanguageModes: [.v5]
)
