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
        .library(name: "FeatureNotify", targets: ["FeatureNotify"]),
        .library(name: "FeatureContacts", targets: ["FeatureContacts"]),
        .library(name: "FeatureCalls", targets: ["FeatureCalls"]),
        .library(name: "FeatureFiles", targets: ["FeatureFiles"]),
        .library(name: "AppSession", targets: ["AppSession"]),
        .executable(name: "am-mac-sim", targets: ["am-mac-sim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.29.0")),
        .package(url: "https://github.com/apple/swift-certificates.git", .upToNextMajor(from: "1.6.0")),
        .package(url: "https://github.com/apple/swift-asn1.git", .upToNextMajor(from: "1.0.0")),
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
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        .target(name: "FeatureStatus", dependencies: ["AMProtocol"]),
        .target(name: "FeatureFind", dependencies: ["AMProtocol", "ConnectionCore"]),
        .target(
            name: "FeatureNotify",
            dependencies: ["AMProtocol", "ConnectionCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(
            name: "FeatureContacts",
            dependencies: ["AMProtocol", "ConnectionCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(
            name: "FeatureCalls",
            dependencies: [
                "AMProtocol", "ConnectionCore", "FeatureContacts", "FeatureNotify",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "FeatureFiles",
            dependencies: ["AMProtocol", "ConnectionCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(
            name: "AppSession",
            dependencies: ["AMProtocol", "ConnectionCore", "FeatureNotify", "FeatureContacts", "FeatureCalls"]
        ),
        .executableTarget(
            name: "am-mac-sim",
            dependencies: [
                "AMProtocol", "ConnectionCore", "FeatureFiles",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "AMProtocolTests",
            dependencies: ["AMProtocol"]
        ),
        .testTarget(
            name: "ConnectionCoreTests",
            dependencies: ["ConnectionCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(name: "FeatureStatusTests", dependencies: ["FeatureStatus"]),
        .testTarget(name: "FeatureFindTests", dependencies: ["FeatureFind", "AMProtocol"]),
        .testTarget(
            name: "FeatureNotifyTests",
            dependencies: ["FeatureNotify", "AMProtocol", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(
            name: "FeatureContactsTests",
            dependencies: ["FeatureContacts", "AMProtocol", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(
            name: "FeatureCallsTests",
            dependencies: ["FeatureCalls", "AMProtocol", "FeatureNotify", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(
            name: "FeatureFilesTests",
            dependencies: [
                "FeatureFiles", "AMProtocol", "ConnectionCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "AppSessionTests",
            dependencies: [
                "AppSession", "AMProtocol", "ConnectionCore", "FeatureNotify", "FeatureContacts", "FeatureCalls",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
    ]
)
