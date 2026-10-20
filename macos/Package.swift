// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AqaraMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AqaraMenuBar",
            path: "Sources/AqaraMenuBar"
        ),
        .testTarget(name: "AqaraMenuBarTests", dependencies: ["AqaraMenuBar"])
    ]
)
