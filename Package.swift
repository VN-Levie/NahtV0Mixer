// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NahtV0Mixer",
    defaultLocalization: "en",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "NahtV0Mixer", targets: ["NahtV0MixerApp"]),
        .library(name: "MixerCore", targets: ["MixerCore"]),
        .library(name: "AudioRouting", targets: ["AudioRouting"]),
        .library(name: "MixerWidgetCore", targets: ["MixerWidgetCore"])
    ],
    targets: [
        .target(name: "CMixerDSP", publicHeadersPath: "include"),
        .target(name: "MixerCore"),
        .target(name: "MixerWidgetCore"),
        .target(name: "AudioRouting", dependencies: ["CMixerDSP", "MixerCore"]),
        .executableTarget(name: "NahtV0MixerApp", dependencies: ["MixerCore", "AudioRouting", "MixerWidgetCore"]),
        .testTarget(name: "MixerCoreTests", dependencies: ["MixerCore", "CMixerDSP"]),
        .testTarget(name: "AudioRoutingTests", dependencies: ["AudioRouting"]),
        .testTarget(name: "NahtV0MixerAppTests", dependencies: ["NahtV0MixerApp"]),
        .testTarget(name: "MixerWidgetCoreTests", dependencies: ["MixerWidgetCore"])
    ],
    swiftLanguageModes: [.v5]
)
