// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeyClickyReplay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HeyClickyReplay",
            path: "Sources"
        )
    ]
)
