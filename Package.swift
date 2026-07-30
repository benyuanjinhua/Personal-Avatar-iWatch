// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WristAgentCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(name: "WristAgentCore", targets: ["WristAgentCore"])
    ],
    targets: [
        .target(
            name: "WristAgentCore",
            path: "Shared"
        ),
        .testTarget(
            name: "WristAgentCoreTests",
            dependencies: ["WristAgentCore"],
            path: "Tests"
        )
    ]
)

