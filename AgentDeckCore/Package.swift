// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentDeckCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentDeckCore", targets: ["AgentDeckCore"]),
        // Main-actor observable mirror of the core's state, used by the app's views.
        .library(name: "AgentDeckState", targets: ["AgentDeckState"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "AgentDeckCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "AgentDeckState",
            dependencies: ["AgentDeckCore"]
        ),
        .testTarget(
            name: "AgentDeckStateTests",
            dependencies: ["AgentDeckState", "AgentDeckCore"]
        ),
        .testTarget(
            name: "AgentDeckCoreTests",
            dependencies: ["AgentDeckCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
