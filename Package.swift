// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SteelPlayer",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v14),
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
        // Our fork of FFmpegKit that exposes gmp/gnutls as individual products
        .package(url: "https://github.com/superuser404notfound/FFmpegKit", branch: "main"),
    ],
    targets: [
        .target(
            name: "SteelPlayer",
            dependencies: [
                // Core FFmpeg libraries
                .product(name: "Libavformat", package: "FFmpegKit"),
                .product(name: "Libavcodec", package: "FFmpegKit"),
                .product(name: "Libavutil", package: "FFmpegKit"),
                .product(name: "Libswresample", package: "FFmpegKit"),
                .product(name: "Libswscale", package: "FFmpegKit"),
                // Crypto/TLS deps from our FFmpegKit fork
                .product(name: "gmp", package: "FFmpegKit"),
                .product(name: "nettle", package: "FFmpegKit"),
                .product(name: "hogweed", package: "FFmpegKit"),
                .product(name: "gnutls", package: "FFmpegKit"),
            ],
            resources: [
                .process("Renderer/Shaders.metal"),
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
