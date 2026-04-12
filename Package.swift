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
        // FFmpeg core libraries (prebuilt xcframeworks via kingslay/FFmpegKit).
        // We only pull the individual Libav* products, NOT the full FFmpegKit
        // target which bundles MoltenVK, libass, gnutls, smbclient, etc.
        // Local path to our FFmpegKit fork (with fixed libshaderc bundle ID).
        // Using local path avoids SPM's slow git checkout of the large
        // xcframework binaries checked into the repo.
        .package(path: "../FFmpegKit-fork"),
    ],
    targets: [
        .target(
            name: "SteelPlayer",
            dependencies: [
                // Full FFmpegKit includes all prebuilt dependencies
                // (gmp, gnutls, libdav1d, libsrt, lcms2, libzvbi, etc.)
                // that the individual Libav* xcframeworks link against.
                // Our fork fixes the libshaderc_combined CFBundleIdentifier
                // that breaks Xcode 26's strict embed validation.
                .product(name: "FFmpegKit", package: "FFmpegKit-fork"),
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
