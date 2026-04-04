// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Charmera",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Charmera",
            path: "Charmera",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
