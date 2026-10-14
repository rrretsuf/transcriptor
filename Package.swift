// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcriptor",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Transcriptor", dependencies: ["ObjCTry"], path: "Sources/Transcriptor"),
        .target(name: "ObjCTry", path: "Sources/ObjCTry", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .testTarget(name: "TranscriptorTests", dependencies: ["Transcriptor"], path: "Tests/TranscriptorTests"),
    ]
)
