// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "package-consul",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "ConsulServiceDiscovery",
            targets: ["ConsulServiceDiscovery"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.49.0")),
        .package(url: "https://github.com/apple/swift-service-discovery.git", .upToNextMajor(from: "1.2.0")),
        .package(url: "https://github.com/apple/swift-log", .upToNextMajor(from: "1.0.0"))
    ],
    targets: [
        .target(
            name: "ConsulServiceDiscovery",
            dependencies: [
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "ServiceDiscovery", package: "swift-service-discovery"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ConsulServiceDiscoveryTests",
            dependencies: ["ConsulServiceDiscovery"]
        ),
    ]
)
