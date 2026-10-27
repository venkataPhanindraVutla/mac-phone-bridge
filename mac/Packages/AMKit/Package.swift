// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AMKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AMProtocol", targets: ["AMProtocol"]),
        .library(name: "ConnectionCore", targets: ["ConnectionCore"]),
        .library(name: "FeatureStatus", targets: ["FeatureStatus"]),
        .library(name: "FeatureFind", targets: ["FeatureFind"]),
        .executable(name: "am-mac-sim", targets: ["am-mac-sim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.29.0")),
        .package(url: "https://github.com/apple/swift-certificates.git", .upToNextMajor(from: "1.6.0")),
    ],
    targets: [
        .target(
            name: "AMProtocol",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(
            name: "ConnectionCore",
            dependencies: [
                "AMProtocol",
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .target(name: "FeatureStatus", dependencies: ["AMProtocol"]),
        .target(name: "FeatureFind", dependencies: ["AMProtocol"]),
        .executableTarget(name: "am-mac-sim", dependencies: ["AMProtocol", "ConnectionCore"]),
        .testTarget(
            name: "AMProtocolTests",
            dependencies: ["AMProtocol"]
        ),
        .testTarget(name: "ConnectionCoreTests", dependencies: ["ConnectionCore"]),
        .testTarget(name: "FeatureStatusTests", dependencies: ["FeatureStatus"]),
        .testTarget(name: "FeatureFindTests", dependencies: ["FeatureFind"]),
    ]
)
