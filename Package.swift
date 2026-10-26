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
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
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
        // D153: the combined status icon (battery ring, network glyph, volume),
        // ported from Status Trio 1.6.0 under the Apache License 2.0
        // (THIRD_PARTY_NOTICES.md).
        .target(
            name: "CombinedStatusIcon",
            path: "Sources/CombinedStatusIcon"
        ),
        .systemLibrary(
            name: "CSQLite"
        ),
        .executableTarget(
            name: "StorageCleanerMac",
            dependencies: [
                "CombinedStatusIcon",
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
        // D153: Status Trio 1.6.0's tests of the ported icon code (Apache
        // License 2.0) and this app's tests of the module. No test in it shows
        // a window: the module draws offscreen and onto a button it is given.
        .testTarget(
            name: "CombinedStatusIconTests",
            dependencies: ["CombinedStatusIcon"],
            path: "Tests/CombinedStatusIconTests"
        ),
        // D106: a load-time constructor that installs the display gate in
        // the test bundle before any test runs (TestDisplayGateBootstrap).
        .target(name: "StorageCleanerTestDisplayBootstrap", path: "Tests/StorageCleanerTestDisplayBootstrap"),
        .testTarget(
            name: "StorageCleanerMacTests",
            dependencies: ["StorageCleanerMac", "CombinedStatusIcon", "FanControlShared", "FileOperationShared", "UninstallHandoffShared", "CSQLite",
                           "StorageCleanerTestDisplayBootstrap"],
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
