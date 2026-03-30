// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmarWave",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .watchOS(.v7),
        .tvOS(.v14),
    ],
    products: [
        .library(
            name: "AmarWave",
            targets: ["AmarWave"]
        ),
    ],
    targets: [
        .target(
            name: "AmarWave",
            path: "Sources/AmarWave"
        ),
        .testTarget(
            name: "AmarWaveTests",
            dependencies: ["AmarWave"],
            path: "Tests/AmarWaveTests"
        ),
    ]
)
