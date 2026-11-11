// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexProxyLauncher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexProxyLauncher", targets: ["CodexProxyLauncher"]),
        .executable(name: "CodexNativeProxy", targets: ["CodexNativeProxy"]),
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
        .executableTarget(name: "CodexNativeProxy", dependencies: ["CodexProxyLauncherCore"]),
        .testTarget(
            name: "CodexProxyLauncherCoreTests",
            dependencies: ["CodexProxyLauncherCore"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
