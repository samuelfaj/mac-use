// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "mac-use",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mac-use-mcp", targets: ["MacUseServer"]),
        .library(name: "MacUse", targets: ["MacUse"]),
    ],
    targets: [
        .target(name: "MacUse"),
        .executableTarget(name: "MacUseServer", dependencies: ["MacUse"]),
        .testTarget(name: "MacUseTests", dependencies: ["MacUse"]),
    ]
)
