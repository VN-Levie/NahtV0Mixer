// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NahtV0Mixer",
    defaultLocalization: "en",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "NahtV0Mixer", targets: ["NahtV0MixerApp"])],
    targets: [
        .target(name: "CMixerDSP", publicHeadersPath: "include"),
        .target(name: "MixerCore"),
        .target(name: "AudioRouting", dependencies: ["CMixerDSP", "MixerCore"]),
        .executableTarget(name: "NahtV0MixerApp", dependencies: ["MixerCore", "AudioRouting"]),
        .testTarget(name: "MixerCoreTests", dependencies: ["MixerCore", "CMixerDSP"]),
        .testTarget(name: "AudioRoutingTests", dependencies: ["AudioRouting"]),
        .testTarget(name: "NahtV0MixerAppTests", dependencies: ["NahtV0MixerApp"])
    ],
    swiftLanguageModes: [.v5]
)
