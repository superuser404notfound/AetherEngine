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
    dependencies: [
        // FFmpeg core libraries (prebuilt xcframeworks via kingslay/FFmpegKit).
        // We only pull the individual Libav* products, NOT the full FFmpegKit
        // target which bundles MoltenVK, libass, gnutls, smbclient, etc.
        .package(url: "https://github.com/kingslay/FFmpegKit", from: "6.1.0"),
    ],
    targets: [
        .target(
            name: "SteelPlayer",
            dependencies: [
                .product(name: "Libavformat", package: "FFmpegKit"),
                .product(name: "Libavcodec", package: "FFmpegKit"),
                .product(name: "Libavutil", package: "FFmpegKit"),
                .product(name: "Libswresample", package: "FFmpegKit"),
                .product(name: "Libswscale", package: "FFmpegKit"),
            ],
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
