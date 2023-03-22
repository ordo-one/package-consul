// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "package-consul",
    products: [
        .library(
            name: "ConsulServiceDiscovery",
            targets: ["ConsulServiceDiscovery"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-service-discovery.git", branch: "main"),
        .package(url: "https://github.com/swift-extras/swift-extras-json.git", .upToNextMajor(from: "0.6.0"))
    ],
    targets: [
        .target(
            name: "ConsulServiceDiscovery",
            dependencies: [
                .product(name: "ExtrasJSON", package: "swift-extras-json"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "ServiceDiscovery", package: "swift-service-discovery"),
            ]
        ),
        .testTarget(
            name: "ConsulServiceDiscoveryTests",
            dependencies: ["ConsulServiceDiscovery"]
        ),
    ]
)
