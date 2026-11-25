// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RobustaCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RobustaCore", targets: ["RobustaCore"]),
    ],
    targets: [
        .target(name: "RobustaCore"),
        .testTarget(
            name: "RobustaCoreTests",
            dependencies: ["RobustaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
