// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Yemma4",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "Yemma4",
            targets: ["Yemma4"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/exyte/Chat.git", from: "2.7.8"),
        .package(url: "https://github.com/mattt/llama.swift.git", from: "2.8640.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "Yemma4",
            path: "Yemma4"
        )
    ]
)
