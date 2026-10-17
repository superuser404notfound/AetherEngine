// swift-tools-version: 6.1

import PackageDescription

// A consumer of the engine with every optional component enabled, the way a host enables them. `swift
// build` on the engine compiles its own traits, but xcodebuild has no flag for a package's traits, so CI
// builds this package for tvOS and iOS to keep the opt-in code compiling for the device SDKs.
let package = Package(
    name: "AetherEngineAllTraits",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AetherEngineAllTraits", targets: ["AetherEngineAllTraits"]),
    ],
    dependencies: [
        .package(
            name: "AetherEngine",
            path: "../..",
            traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DualLayerDolbyVision", "DolbyVisionStillReshaping"]
        ),
    ],
    targets: [
        .target(
            name: "AetherEngineAllTraits",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
