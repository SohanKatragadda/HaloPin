// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HaloPin",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "HaloPin", targets: ["HaloPin"]),
        .executable(name: "HaloPinFixture", targets: ["HaloPinFixture"])
    ],
    targets: [
        .executableTarget(
            name: "HaloPin",
            path: "Sources/HaloPin"
        ),
        .executableTarget(
            name: "HaloPinFixture",
            path: "Sources/HaloPinFixture"
        ),
        .testTarget(
            name: "HaloPinTests",
            dependencies: ["HaloPin"],
            path: "Tests/HaloPinTests"
        )
    ]
)
