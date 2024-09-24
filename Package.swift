// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "BCSwiftNFC",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17),
    ],
    products: [
        .library(
            name: "NFC",
            targets: ["NFC"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "NFC",
            dependencies: []),
        .testTarget(
            name: "NFCTests",
            dependencies: ["NFC"]),
    ]
)
