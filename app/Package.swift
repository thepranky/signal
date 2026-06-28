// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Signal",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.3")
    ],
    targets: [
        .executableTarget(
            name: "Signal",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Signal"
        )
    ]
)
