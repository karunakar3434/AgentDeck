// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentDeckCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentDeckCore", targets: ["AgentDeckCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "AgentDeckCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "AgentDeckCoreTests",
            dependencies: ["AgentDeckCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
