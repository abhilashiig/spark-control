// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SparkControl",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SparkControl",
            path: "Sources/SparkControl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
