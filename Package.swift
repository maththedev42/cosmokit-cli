// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cosmokit-cli",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cosmokit", targets: ["cosmokit"])
    ],
    targets: [
        .target(name: "CosmoKitCLI", path: "Sources/CosmoKitCLI"),
        .executableTarget(name: "cosmokit", dependencies: ["CosmoKitCLI"], path: "Sources/cosmokit"),
        .testTarget(name: "CosmoKitCLITests", dependencies: ["CosmoKitCLI"], path: "Tests/CosmoKitCLITests"),
    ]
)
