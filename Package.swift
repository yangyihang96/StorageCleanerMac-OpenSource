// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StorageCleanerMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StorageCleanerUpdateAskpass", targets: ["StorageCleanerUpdateAskpass"]),
        .executable(name: "StorageCleanerFileOperationHelper", targets: ["StorageCleanerFileOperationHelper"]),
        .executable(name: "StorageCleanerMac", targets: ["StorageCleanerMac"]),
        .executable(name: "StorageCleanerFinderExtension", targets: ["StorageCleanerFinderExtension"]),
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
        .executableTarget(name: "StorageCleanerUpdateAskpass", dependencies: ["FileOperationShared"], path: "Sources/UpdateAskpass"),
        .target(name: "FileOperationShared"),
        .target(name: "UninstallHandoffShared"),
        // D88: Finder Sync extension executable; script/build_and_run.sh wraps
        // it in Contents/PlugIns/StorageCleanerFinderExtension.appex.
        .executableTarget(name: "StorageCleanerFinderExtension", dependencies: ["UninstallHandoffShared"],
                          path: "Sources/FinderUninstallExtension",
                          linkerSettings: [.linkedFramework("FinderSync"), .linkedFramework("AppKit")]),
        .executableTarget(name: "StorageCleanerFileOperationHelper", dependencies: ["FileOperationShared"], path: "Sources/FileOperationHelper", linkerSettings: [.linkedFramework("Security"), .linkedFramework("AppKit")]),
        .target(name: "MSeriesKernels", path: "Sources/MSeriesKernels",
                publicHeadersPath: "include", linkerSettings: [.linkedLibrary("compression")]),
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
                "FileOperationShared",
                "UninstallHandoffShared",
                "CSQLite",
                "MSeriesKernels",
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
            dependencies: ["StorageCleanerMac", "FanControlShared", "FileOperationShared", "UninstallHandoffShared", "CSQLite"],
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
