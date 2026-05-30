// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DropItDown",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DropItDown",
            path: "Sources/DropItDown",
            resources: [
                .copy("../../Resources/Info.plist")
            ]
        )
    ]
)
