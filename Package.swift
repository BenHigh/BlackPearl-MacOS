// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlackPearl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BlackPearl",
            path: "Sources/BlackPearl",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "BlackPearlTests",
            dependencies: ["BlackPearl"],
            path: "Tests/BlackPearlTests"
        ),
    ]
)
