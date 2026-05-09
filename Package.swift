// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AetherEngine",
            targets: ["AetherEngine"]
        ),
        // Standalone CLI used for offline reproduction of the host-side
        // HLSVideoEngine playback symptoms on macOS, without going
        // through TestFlight + Apple TV. Builds only on macOS in
        // practice (Apple platform reqs match the lib target).
        .executable(name: "aetherctl", targets: ["aetherctl"]),
    ],
    dependencies: [
        // Minimal FFmpeg build (avcodec, avformat, avutil, swresample only).
        // No network stack — we use custom AVIO + URLSession for HTTP streams.
        // Resolved over Git rather than a local path so consumers (and
        // Xcode Cloud) can build without a sibling FFmpegBuild checkout.
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", branch: "main"),
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "FFmpegBuild", package: "FFmpegBuild"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "aetherctl",
            dependencies: ["AetherEngine"],
            path: "Sources/aetherctl"
        ),
    ]
)
