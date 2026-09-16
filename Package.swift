// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcriptor",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Transcriptor", path: "Sources/Transcriptor"),
        .testTarget(name: "TranscriptorTests", dependencies: ["Transcriptor"], path: "Tests/TranscriptorTests"),
    ]
)
