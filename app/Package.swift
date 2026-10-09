// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Parakeet",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.4"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        // Its manifest needs swift-tools-version 6.2, so Xcode 26+.
        .package(url: "https://github.com/jaywcjlove/PermissionFlow", exact: "2.11.2"),
    ],
    targets: [
        .executableTarget(
            name: "Parakeet",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PermissionFlow", package: "PermissionFlow"),
            ],
            path: "Sources/Parakeet",
            // Sparkle.framework is copied into Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
