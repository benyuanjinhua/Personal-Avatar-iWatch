// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudioPipe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "audiopipe", path: "Sources/audiopipe")
    ]
)
