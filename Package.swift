// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Yemma4",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Yemma4",
            targets: ["Yemma4"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/exyte/Chat.git", from: "2.7.8"),
        .package(url: "https://github.com/exyte/MediaPicker.git", exact: "3.2.4"),
        .package(url: "https://github.com/mattt/llama.swift.git", from: "2.8660.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1")
    ],
    targets: [
        .target(
            name: "Yemma4",
            dependencies: [
                .product(name: "ExyteChat", package: "Chat"),
                .product(name: "LlamaSwift", package: "llama.swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Yemma4",
            exclude: [
                "Yemma4.entitlements",
            ]
        )
    ]
)
