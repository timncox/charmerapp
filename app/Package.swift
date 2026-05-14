// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Charmera",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "CharmeraCore",
            path: "CharmeraCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Charmera",
            dependencies: ["CharmeraCore"],
            path: "Charmera",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "charmera-mcp",
            dependencies: [
                "CharmeraCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "charmera-mcp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
