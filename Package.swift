// swift-tools-version:5.6

import PackageDescription

let package = Package(
    name: "BCSwiftNFC",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "NFC",
            targets: ["NFC"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/WolfMcNally/WolfBase",
            from: "4.0.0"
        ),
    ],
    targets: [
        .target(
            name: "NFC",
            dependencies: ["WolfBase"]),
        .testTarget(
            name: "NFCTests",
            dependencies: ["NFC"]),
    ]
)
