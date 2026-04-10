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
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
        .package(path: "../mlx-vlm-swift/mlx-swift-lm"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            .upToNextMinor(from: "1.1.0")
        ),
    ],
    targets: [
        .target(
            name: "Yemma4",
            dependencies: [
                .product(name: "ExyteChat", package: "Chat"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Yemma4",
            exclude: [
                "Yemma4.entitlements",
            ]
        )
    ]
)
