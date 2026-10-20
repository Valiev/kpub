// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kpub",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kpub", targets: ["Kpub"]),
    ],
    targets: [
        .target(name: "KpubCore", path: "Sources/KpubCore"),
        .executableTarget(
            name: "Kpub",
            dependencies: ["KpubCore"],
            path: "Sources/Kpub"
        ),
        .testTarget(
            name: "KpubCoreTests",
            dependencies: ["KpubCore"],
            path: "Tests/KpubCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
