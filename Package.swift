// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexProxyLauncher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexProxyLauncher", targets: ["CodexProxyLauncher"]),
        .library(name: "CodexProxyLauncherCore", targets: ["CodexProxyLauncherCore"])
    ],
    targets: [
        .target(
            name: "CodexProxyLauncherCore"
        ),
        .executableTarget(
            name: "CodexProxyLauncher",
            dependencies: ["CodexProxyLauncherCore"]
        ),
        .testTarget(
            name: "CodexProxyLauncherCoreTests",
            dependencies: ["CodexProxyLauncherCore"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
