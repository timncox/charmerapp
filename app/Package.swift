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
        .testTarget(
            name: "CharmeraCoreTests",
            dependencies: ["CharmeraCore"],
            path: "CharmeraCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // CLT-only workaround: Testing.framework lives outside the default rpath on
                // systems where only Command Line Tools are installed (no Xcode).
                // When Xcode is installed this rpath is harmless; it just won't be needed.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ]
        ),
    ]
)
