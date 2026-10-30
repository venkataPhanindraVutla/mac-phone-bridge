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
        .library(name: "FeatureClipboard", targets: ["FeatureClipboard"]),
        .library(name: "FeatureShare", targets: ["FeatureShare"]),
        .library(name: "FeatureScreenshots", targets: ["FeatureScreenshots"]),
        .library(name: "FeaturePhotos", targets: ["FeaturePhotos"]),
        .library(name: "FeatureBrowse", targets: ["FeatureBrowse"]),
        .library(name: "FeatureMedia", targets: ["FeatureMedia"]),
        .library(name: "FeatureFocus", targets: ["FeatureFocus"]),
        .library(name: "FeatureProximity", targets: ["FeatureProximity"]),
        .library(name: "AppSession", targets: ["AppSession"]),
        // The Full build's extensions and the app's FULL_BUILD code only (docs/ARCHITECTURE.md section 4).
        .library(name: "FileProviderShared", targets: ["FileProviderShared"]),
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
            name: "FeatureClipboard",
            dependencies: ["AMProtocol", "ConnectionCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(
            name: "FeatureShare",
            dependencies: [
                "FeatureClipboard", "FeatureNotify", "AMProtocol", "ConnectionCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "FeatureScreenshots",
            dependencies: ["FeatureFiles", "FeatureNotify", "AMProtocol", "ConnectionCore"]
        ),
        .target(
            name: "FeaturePhotos",
            dependencies: [
                "FeatureFiles", "AMProtocol", "ConnectionCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "FeatureBrowse",
            dependencies: [
                "FeatureFiles", "AMProtocol", "ConnectionCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "FeatureMedia",
            dependencies: ["AMProtocol", "ConnectionCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
            linkerSettings: [.linkedFramework("MediaPlayer")]
        ),
        .target(
            name: "FeatureFocus",
            dependencies: ["AMProtocol", "ConnectionCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
            linkerSettings: [.linkedFramework("Intents")]
        ),
        .target(
            name: "FeatureProximity",
            dependencies: ["AMProtocol", "ConnectionCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
            linkerSettings: [.linkedFramework("CoreBluetooth")]
        ),
        .target(
            name: "AppSession",
            dependencies: ["AMProtocol", "ConnectionCore", "FeatureNotify", "FeatureContacts", "FeatureCalls"]
        ),
        // Foundation only: the sandboxed extensions link it too.
        .target(name: "FileProviderShared"),
        // Test doubles and helpers shared by the test targets. No product exports it, so the app
        // and the extensions can never link it; only test targets depend on it.
        .target(
            name: "AMTestSupport",
            dependencies: ["AMProtocol", "ConnectionCore", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .executableTarget(
            name: "am-mac-sim",
            dependencies: [
                "AMProtocol", "ConnectionCore", "FeatureFiles", "FeatureMedia",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "AMProtocolTests",
            dependencies: ["AMProtocol"]
        ),
        .testTarget(
            name: "ConnectionCoreTests",
            dependencies: ["ConnectionCore", "AMTestSupport", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
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
                "FeatureFiles", "AMProtocol", "ConnectionCore", "AMTestSupport",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "FeatureClipboardTests",
            dependencies: ["FeatureClipboard", "AMProtocol", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(
            name: "FeatureShareTests",
            dependencies: [
                "FeatureShare", "FeatureClipboard", "FeatureNotify", "AMProtocol",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "FeatureScreenshotsTests",
            dependencies: [
                "FeatureScreenshots", "FeatureFiles", "FeatureNotify", "AMProtocol",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "FeaturePhotosTests",
            dependencies: [
                "FeaturePhotos", "FeatureFiles", "AMProtocol", "ConnectionCore", "AMTestSupport",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "FeatureBrowseTests",
            dependencies: [
                "FeatureBrowse", "FeatureFiles", "AMProtocol", "ConnectionCore", "AMTestSupport",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "FeatureMediaTests",
            dependencies: ["FeatureMedia", "AMProtocol", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(
            name: "FeatureFocusTests",
            dependencies: ["FeatureFocus", "AMProtocol", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(
            name: "FeatureProximityTests",
            dependencies: [
                "FeatureProximity", "AMProtocol", "ConnectionCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(name: "FileProviderSharedTests", dependencies: ["FileProviderShared"]),
        .testTarget(
            name: "AppSessionTests",
            dependencies: [
                "AppSession", "AMProtocol", "ConnectionCore", "FeatureNotify", "FeatureContacts", "FeatureCalls",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
    ]
)
