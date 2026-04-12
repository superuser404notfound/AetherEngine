// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SteelPlayer",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SteelPlayer",
            targets: ["SteelPlayer"]
        ),
    ],
    targets: [
        .target(
            name: "SteelPlayer",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
