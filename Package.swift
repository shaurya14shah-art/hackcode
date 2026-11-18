// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HackCode",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HackCode", targets: ["HackCode"]),
        .library(name: "HackCodeKit", targets: ["HackCodeKit"]),
    ],
    targets: [
        // UI-free core: execution boundary, LLM client, monitoring, security audit.
        .target(name: "HackCodeKit", path: "Sources/HackCodeKit"),
        // SwiftUI application shell.
        .executableTarget(name: "HackCode", dependencies: ["HackCodeKit"], path: "Sources/HackCode"),
        .testTarget(name: "HackCodeKitTests", dependencies: ["HackCodeKit"], path: "Tests/HackCodeKitTests"),
    ]
)
