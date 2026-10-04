// swift-tools-version: 5.10
import Foundation
import PackageDescription

let benchmarkInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Resources/BenchmarkInfo.plist").path

let package = Package(
    name: "hearsay",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "8d86630ade569728aaea3dc1a29fc44e2efa719b"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
        // PINNED_MLX_METAL_VERSION: scripts/local-inference-resources.sh bundles this release's shaders.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
    ],
    targets: [
        .target(name: "Utterance"),
        .target(name: "Audio"),
        .target(
            name: "Transcription",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]),
        .target(name: "Polish"),
        .target(name: "Insertion"),
        .target(name: "History"),
        .target(name: "Overlay"),
        .target(name: "Bakeoff"),
        .target(name: "Lexicon"),
        .target(name: "Pipeline", dependencies: ["Transcription", "Polish", "Lexicon"]),
        .target(
            name: "Benchmark", dependencies: ["Pipeline", "Bakeoff", "Transcription", "Polish", "Lexicon"],
            resources: [.process("Resources")]),
        .executableTarget(
            name: "hearsay-benchmark", dependencies: ["Benchmark", "Audio", "Pipeline", "Transcription"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", benchmarkInfoPlist])
            ]
        ),
        .executableTarget(name: "bakeoff-tests", dependencies: ["Bakeoff"]),
        .executableTarget(name: "hearsay-check", dependencies: ["Transcription", "Polish"]),
        .executableTarget(
            name: "hearsay",
            dependencies: [
                "Utterance", "Audio", "Transcription", "Polish", "Insertion", "History", "Overlay", "Bakeoff", "Lexicon", "Pipeline",
            ]
        ),
        .testTarget(name: "BenchmarkTests", dependencies: ["Benchmark", "Pipeline", "Transcription", "Polish", "Lexicon"]),
        .testTarget(name: "OverlayTests", dependencies: ["Overlay"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"]),
        .testTarget(name: "UtteranceTests", dependencies: ["Utterance"]),
        .testTarget(name: "HearsayAppTests", dependencies: ["hearsay"]),
        .testTarget(name: "PolishTests", dependencies: ["Polish"]),
    ]
)
