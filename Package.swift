// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SparkControl",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The Terminal page's emulator (xterm-256color, mouse, resize). Pinned; bump on purpose.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "SparkControl",
            dependencies: ["SwiftTerm"],
            path: "Sources/SparkControl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
