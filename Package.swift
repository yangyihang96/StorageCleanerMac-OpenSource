// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StorageCleanerMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StorageCleanerMac", targets: ["StorageCleanerMac"]),
        .executable(
            name: "StorageCleanerFanControlHelper",
            targets: ["StorageCleanerFanControlHelper"]
        ),
        .executable(
            name: "MemoryFixtureApp",
            targets: ["MemoryFixtureApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .target(
            name: "FanControlShared",
            path: "Sources/FanControlShared"
        ),
        .systemLibrary(
            name: "CSQLite"
        ),
        .executableTarget(
            name: "StorageCleanerMac",
            dependencies: [
                "FanControlShared",
                "CSQLite",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [
                .define(
                    "STORAGE_CLEANER_RELEASE_BUILD",
                    .when(configuration: .release)
                )
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .executableTarget(
            name: "StorageCleanerFanControlHelper",
            dependencies: ["FanControlShared"],
            path: "Sources/FanControlHelper",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "MemoryFixtureApp",
            path: "Tests/StorageCleanerMacTests/Fixtures/MemoryFixtureApp"
        ),
        .testTarget(
            name: "StorageCleanerMacTests",
            dependencies: ["StorageCleanerMac", "FanControlShared", "CSQLite"],
            exclude: ["Fixtures"],
            swiftSettings: [
                .define(
                    "STORAGE_CLEANER_RELEASE_BUILD",
                    .when(configuration: .release)
                )
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../.."
                ])
            ]
        )
    ]
)
