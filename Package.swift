// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RawParserKit",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(
            name: "RawParserKit",
            targets: ["RawParserKit"]
        )
    ],
    targets: [
        .target(
            name: "RawParserKit",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "RawParserKitTests",
            dependencies: ["RawParserKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
