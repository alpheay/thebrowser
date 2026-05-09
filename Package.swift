// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TheBrowser",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TheBrowser", targets: ["TheBrowser"])
    ],
    targets: [
        .executableTarget(name: "TheBrowser")
    ]
)
