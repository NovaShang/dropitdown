// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DropItDown",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "DropItDown",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/DropItDown",
            resources: [
                .copy("../../Resources/Info.plist")
            ]
        )
    ]
)
