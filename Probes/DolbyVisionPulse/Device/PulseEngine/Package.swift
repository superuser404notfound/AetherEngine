// swift-tools-version: 6.1

import PackageDescription

// The engine as the pulse host needs it: with the DualLayerDolbyVision trait, without which every
// `engine` and `soak` arm would measure the native route. XcodeGen cannot set a package's traits, so
// the host depends on this package and this package sets them.
let package = Package(
    name: "PulseEngine",
    platforms: [.tvOS(.v18)],
    products: [
        .library(name: "PulseEngine", targets: ["PulseEngine"]),
    ],
    dependencies: [
        .package(name: "AetherEngine", path: "../../../..", traits: ["DualLayerDolbyVision"]),
    ],
    targets: [
        .target(name: "PulseEngine", dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]),
    ]
)
