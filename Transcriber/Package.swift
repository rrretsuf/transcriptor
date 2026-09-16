// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Transcriber", path: "Sources/Transcriber"),
        .testTarget(name: "TranscriberTests", dependencies: ["Transcriber"], path: "Tests/TranscriberTests"),
    ]
)
