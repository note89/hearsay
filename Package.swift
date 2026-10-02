// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "hearsay",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "Utterance"),
        .target(name: "Audio"),
        .target(name: "Transcription"),
        .target(name: "Polish"),
        .target(name: "Insertion"),
        .target(name: "History"),
        .target(name: "Overlay"),
        .target(name: "Bakeoff"),
        .target(name: "Lexicon"),
        .executableTarget(name: "bakeoff-tests", dependencies: ["Bakeoff"]),
        .executableTarget(name: "hearsay-check", dependencies: ["Transcription", "Polish"]),
        .executableTarget(
            name: "hearsay",
            dependencies: ["Utterance", "Audio", "Transcription", "Polish", "Insertion", "History", "Overlay", "Bakeoff", "Lexicon"]
        ),
        .testTarget(name: "OverlayTests", dependencies: ["Overlay"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"]),
        .testTarget(name: "UtteranceTests", dependencies: ["Utterance"]),
        .testTarget(name: "HearsayAppTests", dependencies: ["hearsay"]),
    ]
)
