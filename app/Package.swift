// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Signal",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Signal",
            path: "Sources/Signal"
        )
    ]
)
