// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cosmokit-cli",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cosmokit", targets: ["cosmokit"])
    ],
    targets: [
        .executableTarget(name: "cosmokit", path: "Sources/cosmokit")
    ]
)
