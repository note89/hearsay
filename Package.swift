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
        .target(name: "Bakeoff", dependencies: ["Insertion"]),
        .target(name: "Lexicon"),
        .executableTarget(
            name: "hearsay",
            dependencies: ["Utterance", "Audio", "Transcription", "Polish", "Insertion", "History", "Overlay", "Bakeoff", "Lexicon"]
        ),
    ]
)
