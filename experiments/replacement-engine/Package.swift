// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HIR249ReplacementEngine",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "replacement-engine", targets: ["ReplacementEngine"]),
    ],
    targets: [
        .executableTarget(
            name: "ReplacementEngine",
            path: "Sources/ReplacementEngine"
        ),
    ]
)
