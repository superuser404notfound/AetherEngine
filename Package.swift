// swift-tools-version: 6.0

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
        // Minimal FFmpeg build (avcodec, avformat, avutil, swresample only).
        // No network stack — we use custom AVIO + URLSession for HTTP streams.
        .package(path: "../FFmpegBuild"),
    ],
    targets: [
        .target(
            name: "SteelPlayer",
            dependencies: [
                .product(name: "FFmpegBuild", package: "FFmpegBuild"),
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
