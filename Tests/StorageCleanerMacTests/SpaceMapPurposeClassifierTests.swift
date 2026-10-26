import Foundation
import XCTest
@testable import StorageCleanerMac

final class SpaceMapPurposeClassifierTests: XCTestCase {
    func testOwnDirectoryNamesWinAndUnknownDirectoriesAndFilesInherit() throws {
        let purposes = try classify([
            .directory("SrC", [.directory("tries", [.directory("run", [.file("cache", 1)])]),
                               .file(".codex", 1)]),
            .file("cache", 1)
        ])
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/SrC"), .code)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/SrC/tries"), .agentWorkspace)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/SrC/tries/run"), .agentWorkspace)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/SrC/tries/run/cache"), .agentWorkspace)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/SrC/.codex"), .code)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/cache"), .other)
        XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/SrC/tries/run/cache"))
    }

    func testUnknownTopLevelUsesLargestRecognizedDirectoryAndLeavesUnknownAlone() throws {
        let purposes = try classify([
            .directory("world", [.directory(".git", [.file("pack", 90)]),
                                  .directory("cache", [.file("data", 10)]), .directory("unclassified", [])]),
            .directory("mystery", [.file("data", 50)])
        ])
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/world"), .git)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/world/unclassified"), .git)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery"), .other)
        XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/world"), "Inferred purpose never promotes a child's reclaim reason")
    }

    func testDominantSearchFollowsLargestUnknownBranchAndStopsAfterThreeLevels() throws {
        let purposes = try classify([
            .directory("three", [.directory("a", [.directory("b", [.directory("src", [.file("code", 60)])])]),
                                  .file("other", 40)]),
            .directory("four", [.directory("a", [.directory("b", [.directory("c", [.directory("src", [.file("code", 10)])])])])]),
            .directory("branch", [.directory("large", [.file("data", 100)]),
                                   .directory("small", [.directory("src", [.file("code", 1)])])]),
            .directory("too-small", [.directory("a", [.directory("b", [.directory("src", [.file("code", 49)])])]),
                                      .file("other", 51)])
        ])
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/three"), .code)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/four"), .other)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/branch"), .other)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/too-small"), .other)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/too-small/a/b/src"), .code)
    }

    func testHomeLibraryDoesNotInferPurposeFromCachesOrSyncedFolders() throws {
        let home = "/Users/tester"
        let index = SpaceMapMemoryIndex.make(rootPath: home, children: [
            .directory("Library", [.directory("Application Support", [.file("data", 60)]),
                                    .directory("Containers", []),
                                    .directory("Caches", [.file("data", 20)]),
                                    .directory("Mobile Documents", [.file("data", 20)])])
        ])
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: home))
        for path in ["Library", "Library/Application Support", "Library/Containers"] {
            XCTAssertEqual(purposes.purpose(atPath: home + "/" + path), .other, path)
        }
        XCTAssertEqual(purposes.purpose(atPath: home + "/Library/Caches"), .cache)
        XCTAssertEqual(purposes.purpose(atPath: home + "/Library/Mobile Documents"), .synced)
    }

    func testOnlyHomeLibraryApplicationsAndDeveloperStopDominantInference() throws {
        let cases: [(String, SpaceMapPurpose)] = [
            ("LiBrArY", .other), ("APPLICATIONS", .other), ("Developer", .other),
            ("System", .cache), ("Users", .cache), ("Private", .cache), ("Volumes", .cache),
            ("opt", .cache), ("usr", .cache), ("bin", .cache), ("sbin", .cache),
            ("cores", .cache), ("Network", .cache)
        ]
        let purposes = try classify(cases.map {
            .directory($0.0, [.directory("Caches", [.file("data", 80)]), .file("other", 20)])
        })
        for (name, expected) in cases {
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/" + name), expected, name)
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/" + name + "/Caches"), .cache, name)
            XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/" + name + "/Caches"), .regenerableCache, name)
        }
    }

    func testVolumeStructuralDirectoriesDoNotInferEvenWithAMajority() throws {
        let names = ["LiBrArY", "APPLICATIONS", "System", "Users", "Private", "Volumes",
                     "opt", "usr", "bin", "sbin", "cores", "Network", "Developer"]
        for root in ["/", "/Volumes/Ext"] {
            let index = SpaceMapMemoryIndex.make(rootPath: root, children: names.map {
                .directory($0, [.directory("Caches", [.file("data", 80)]), .file("other", 20)])
            })
            let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/Users/tester"))
            for name in names {
                let path = StorageMapAnalysisIndex.childPath(name, in: root)
                XCTAssertEqual(purposes.purpose(atPath: path), .other, path)
                XCTAssertEqual(purposes.purpose(atPath: path + "/Caches"), .cache, path)
                XCTAssertEqual(purposes.reclaimReason(atPath: path + "/Caches"), .regenerableCache, path)
            }
        }
    }

    func testStructuralNamesAtOtherAnalysisRootsAllowDominantInference() throws {
        let names = ["Library", "Applications", "Developer", "bin", "opt"]
        for root in ["/Users/tester/Projects", "/Volumes/Ext/Projects"] {
            let index = SpaceMapMemoryIndex.make(rootPath: root, children: names.map {
                .directory($0, [.directory("Caches", [.file("data", 80)]), .file("other", 20)])
            })
            let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/Users/tester"))
            for name in names {
                XCTAssertEqual(purposes.purpose(atPath: root + "/" + name), .cache, root + "/" + name)
            }
        }
    }

    func testHomeDeveloperStaysOtherAndHomeBinCanInferBareRepositoryWhenScanningHomeOrSlash() throws {
        let home = "/Users/tester"
        let bare: SpaceMapMemoryNode = .directory("bare", [
            .directory("objects", [.file("pack", 99)]), .directory("refs", []), .file("HEAD", 1)
        ])
        let homeChildren: [SpaceMapMemoryNode] = [
            .directory("Developer", [.directory("App", [
                .directory("node_modules", [.file("dependency", 80)]), .file("package.json", 1), .file("other", 19)
            ])]),
            .directory("bin", [bare])
        ]
        for root in [home, "/"] {
            let index = SpaceMapMemoryIndex.make(rootPath: root, children: root == home ? homeChildren : [
                .directory("Users", [.directory("tester", homeChildren)]), .directory("bin", [bare])
            ])
            let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: home))
            XCTAssertEqual(purposes.purpose(atPath: home + "/Developer"), .other, root)
            XCTAssertEqual(purposes.purpose(atPath: home + "/Developer/App/node_modules"), .cache, root)
            XCTAssertEqual(purposes.reclaimReason(atPath: home + "/Developer/App/node_modules"), .reinstallableDependencies, root)
            XCTAssertEqual(purposes.purpose(atPath: home + "/bin"), .git, root)
            XCTAssertEqual(purposes.purpose(atPath: home + "/bin/bare"), .git, root)
            if root == "/" {
                XCTAssertEqual(purposes.purpose(atPath: "/bin"), .other)
                XCTAssertEqual(purposes.purpose(atPath: "/bin/bare"), .git)
            }
        }
    }

    func testUnknownTopLevelDoesNotInferFromASmallerRecognizedSibling() throws {
        let purposes = try classify([
            .directory("mystery", [.directory("opaque", [.file("data", 60)]),
                                    .directory(".git", [.file("pack", 40)])])
        ])
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery"), .other)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery/opaque"), .other)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery/.git"), .git)
    }

    func testDominantPurposeRequiresAtLeastHalfOfTopLevelBytes() throws {
        let cases: [(Int64, Int64, SpaceMapPurpose)] = [
            (50, 100, .code), (49, 100, .other), (50, 101, .other), (51, 101, .code)
        ]
        for (bytes, total, expected) in cases {
            let purposes = try classify([
                .directory("mystery", [.directory("src", [.file("code", bytes)]), .file("other", total - bytes)])
            ])
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery"), expected, "\(bytes)/\(total)")
        }
    }

    func testZeroByteTopLevelDirectoriesDoNotInferRecognizedPurposes() throws {
        let cases: [(String, SpaceMapPurpose)] = [("src", .code), (".git", .git), ("Caches", .cache), ("Dropbox", .synced)]
        for (name, expected) in cases {
            let purposes = try classify([.directory("mystery", [.directory(name, [.file("empty", 0)])])])
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery"), .other, name)
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery/" + name), expected, name)
        }
    }

    func testDominantPurposeBreaksByteTiesByPath() throws {
        let purposes = try classify([
            .directory("recognized-first", [.directory("z-opaque", [.file("data", 50)]),
                                             .directory("src", [.file("code", 50)])]),
            .directory("unknown-first", [.directory("src", [.file("code", 50)]),
                                          .directory("a-opaque", [.file("data", 50)])])
        ])
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/recognized-first"), .code)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/unknown-first"), .other)
    }

    func testDominantPurposeRecognizesBareRepositoriesWithoutOverflowAtTheByteLimit() throws {
        let bytes = Int64.max / 2 + 1
        let purposes = try classify([
            .directory("mystery", [.directory("bare", [.directory("objects", [.file("pack", bytes - 1)]),
                                                       .directory("refs", []), .file("HEAD", 1)]),
                                    .file("other", bytes - 1)])
        ])
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery"), .git)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery/bare"), .git)
    }

    func testBlockedPackagesDoNotCreateRulesForTheirContents() throws {
        for root in ["/analysis", "/analysis/.cache"] {
            let tool = root + "/Tool.app"
            let photos = root + "/照片图库.photoslibrary"
            let blocked: Set<String> = [tool, photos]
            let empty = SpaceMapMemoryIndex.make(rootPath: root, children: [
                .directory("Tool.app", []), .directory("照片图库.photoslibrary", [])
            ], blocked: blocked, packages: blocked)
            let populated = SpaceMapMemoryIndex.make(rootPath: root, children: [
                .directory("Tool.app", [.directory("Contents", [.directory("Resources", [
                    .directory("node_modules", [.file("dependency", 1)]), .file("package.json", 1)
                ])])]),
                .directory("照片图库.photoslibrary", [.directory("resources", [.directory("caches", [.file("photo", 1)])])])
            ], blocked: blocked, packages: blocked)
            let baseline = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: empty, homePath: root))
            let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: populated, homePath: root))
            XCTAssertEqual(purposes.explicitDirectoryCount, baseline.explicitDirectoryCount)
            XCTAssertEqual(purposes.explicitDirectoryCount, root.hasSuffix(".cache") ? 2 : 1)
            XCTAssertEqual(purposes.purpose(atPath: tool), root.hasSuffix(".cache") ? .cache : .other)
            XCTAssertEqual(purposes.purpose(atPath: photos), .media)
            for (package, descendant) in [(tool, "/Contents/Resources/node_modules/dependency"),
                                           (photos, "/resources/caches/photo")] {
                XCTAssertEqual(purposes.purpose(atPath: package), baseline.purpose(atPath: package))
                XCTAssertEqual(purposes.reclaimReason(atPath: package), baseline.reclaimReason(atPath: package))
                XCTAssertEqual(purposes.purpose(atPath: package + descendant), purposes.purpose(atPath: package))
                XCTAssertEqual(purposes.reclaimReason(atPath: package + descendant), purposes.reclaimReason(atPath: package))
            }
        }
    }

    func testBlockedDirectoriesAndAnalysisRootsKeepOnlyTheirOwnRules() throws {
        for root in ["/analysis", "/analysis/src"] {
            let index = SpaceMapMemoryIndex.make(
                rootPath: root,
                children: root == "/analysis"
                    ? [.directory("src", [.directory("Caches", [.file("data", 1)])])]
                    : [.directory("Caches", [.file("data", 1)])],
                blocked: ["/analysis/src"]
            )
            let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis"))
            XCTAssertEqual(purposes.explicitDirectoryCount, 1)
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/src/Caches/data"), .code)
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/src/Caches/data"))
        }
    }

    func testSyncedFoldersSuppressReclaimReasonsButKeepPurposes() throws {
        let names = ["CloudStorage", "Dropbox", "Google Drive", "OneDrive", "OneDrive - Work",
                     "Dropbox (Work)", "Sync", "nextcloud", "pCloudDrive", "MEGA"]
        let purposes = try classify([
            .directory("Mobile Documents", [.directory("com~apple~CloudDocs", [.directory("Project", [
                .directory("node_modules", [.file("dependency", 1)]), .file("package.json", 1),
                .directory("src", [.file("main.swift", 1)])
            ])])])
        ] + names.map { .directory($0, [
            .directory("node_modules", [.file("dependency", 1)]), .file("package.json", 1),
            .directory("Work", [.directory("Cache", [.file("data", 1)]),
                                 .directory("src", [.file("main.swift", 1)])])
        ]) })
        let project = "/analysis/Mobile Documents/com~apple~CloudDocs/Project"
        XCTAssertNil(purposes.reclaimReason(atPath: project + "/node_modules/dependency"))
        XCTAssertEqual(purposes.purpose(atPath: project + "/node_modules"), .cache)
        XCTAssertEqual(purposes.purpose(atPath: project + "/src/main.swift"), .code)
        for name in names {
            let path = "/analysis/" + name
            XCTAssertEqual(purposes.purpose(atPath: path), .synced, name)
            XCTAssertNil(purposes.reclaimReason(atPath: path), name)
            XCTAssertNil(purposes.reclaimReason(atPath: path + "/node_modules/dependency"), name)
            XCTAssertNil(purposes.reclaimReason(atPath: path + "/Work/Cache/data"), name)
            XCTAssertEqual(purposes.purpose(atPath: path + "/Work/Cache"), .cache, name)
            XCTAssertEqual(purposes.purpose(atPath: path + "/Work/src/main.swift"), .code, name)
        }
    }

    func testSyncNamesOutsideRootsKeepReclaimReasons() throws {
        let names = ["Sync", "Dropbox", "MEGA", "Google Drive", "OneDrive", "OneDrive - Work",
                     "Dropbox (Work)", "Nextcloud", "pCloudDrive"]
        let purposes = try classify([
            .directory("Projects", names.map { .directory($0, [
                .directory("node_modules", [.file("dependency", 1)]), .file("package.json", 1)
            ]) }),
            .directory("Library", [.directory("Caches", [.directory("Dropbox", [
                .directory("blobs", [.file("data", 1)])
            ])])])
        ])
        for name in names {
            let path = "/analysis/Projects/" + name
            XCTAssertEqual(purposes.purpose(atPath: path), .synced, name)
            XCTAssertEqual(purposes.reclaimReason(atPath: path + "/node_modules"), .reinstallableDependencies, name)
            XCTAssertEqual(purposes.reclaimReason(atPath: path + "/node_modules/dependency"), .reinstallableDependencies, name)
        }
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/Library/Caches/Dropbox"), .synced)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/Library/Caches/Dropbox/blobs"), .regenerableCache)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/Library/Caches/Dropbox/blobs/data"), .regenerableCache)
    }

    func testLibrarySyncRootsSuppressProviderCaches() throws {
        let purposes = try classify([
            .directory("Library", [
                .directory("CloudStorage", [.directory("Dropbox", [.directory("Cache", [.file("data", 1)])])]),
                .directory("Mobile Documents", [.directory("com~apple~CloudDocs", [
                    .directory("x", [.directory("Cache", [.file("data", 1)])])
                ])])
            ])
        ])
        for path in ["Library/CloudStorage/Dropbox/Cache", "Library/Mobile Documents/com~apple~CloudDocs/x/Cache"] {
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/" + path), .cache, path)
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/" + path), path)
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/" + path + "/data"), path)
        }
    }

    func testSyncRootsClearInheritedReasonsAndKeepSyncHistory() throws {
        let purposes = try classify([
            .directory(".cache", [.directory("Dropbox", [
                .directory("Cache", [.file("data", 1)]),
                .directory(".stversions", [.directory("Cache", [.file("old", 1)])])
            ]), .directory("CloudStorage", [.directory("Cache", [.file("data", 1)])]),
                .directory("Mobile Documents", [.directory("Cache", [.file("data", 1)])])]),
            .directory("Sync", [.directory(".stversions", [.directory("node_modules", [.file("old", 1)]),
                                                           .file("package.json", 1)])])
        ])
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.cache"), .regenerableCache)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.cache/Dropbox"), .regenerableCache)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.cache/Dropbox/Cache/data"), .regenerableCache)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.cache/Dropbox/.stversions/Cache/old"), .syncHistory)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/Sync/.stversions"), .syncHistory)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/Sync/.stversions/node_modules/old"), .syncHistory)
        for name in ["CloudStorage", "Mobile Documents"] {
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/.cache/" + name), name)
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/.cache/" + name + "/Cache/data"), name)
        }
    }

    func testSyncedAnalysisRootsSuppressCatalogAndNameReasons() throws {
        let home = "/analysis/CloudStorage/Dropbox/unrecognized"
        let index = SpaceMapMemoryIndex.make(rootPath: home, children: [
            .directory(".claude", [.directory("logs", [.file("log", 1)])]),
            .directory(".codex", [.directory("tmp", [.file("data", 1)])]),
            .directory(".continue", [.directory("index", [.file("data", 1)])]),
            .directory("Cache", [.file("data", 1)]), .directory("src", [.file("code", 1)])
        ])
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: home))
        for path in [".claude/logs/log", ".codex/tmp/data", ".continue/index/data", "Cache/data"] {
            XCTAssertNil(purposes.reclaimReason(atPath: home + "/" + path), path)
        }
        XCTAssertEqual(purposes.purpose(atPath: home + "/src/code"), .code)
    }

    func testSyncSuppressionUsesAncestorsOfAnalysisRoot() throws {
        let cases: [(String, Bool)] = [
            ("/analysis/Projects/Sync", false), ("/analysis/Projects/MEGA", false),
            ("/analysis/Projects/Dropbox (Work)", false), ("/analysis-elsewhere/Sync", false),
            ("/analysis/Sync", true), ("/analysis/Dropbox/Work", true),
            ("/analysis/Library/CloudStorage/Dropbox", true),
            ("/analysis/Library/Mobile Documents/com~apple~CloudDocs/x", true),
            ("/Volumes/Ext/CloudStorage/Dropbox", true), ("/Volumes/Ext/Mobile Documents/x", true)
        ]
        for (root, inSync) in cases {
            let index = SpaceMapMemoryIndex.make(rootPath: root, children: [
                .directory("node_modules", [.file("dependency", 1)]), .file("package.json", 1),
                .directory("Cache", [.file("data", 1)]),
                .directory(".stversions", [.directory("Cache", [.file("old", 1)])])
            ])
            let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis"))
            XCTAssertEqual(purposes.reclaimReason(atPath: root + "/node_modules"), inSync ? nil : .reinstallableDependencies, root)
            XCTAssertEqual(purposes.reclaimReason(atPath: root + "/node_modules/dependency"), inSync ? nil : .reinstallableDependencies, root)
            XCTAssertEqual(purposes.reclaimReason(atPath: root + "/Cache"), inSync ? nil : .regenerableCache, root)
            XCTAssertEqual(purposes.reclaimReason(atPath: root + "/Cache/data"), inSync ? nil : .regenerableCache, root)
            XCTAssertEqual(purposes.reclaimReason(atPath: root + "/.stversions"), .syncHistory, root)
            XCTAssertEqual(purposes.reclaimReason(atPath: root + "/.stversions/Cache/old"), .syncHistory, root)
        }
    }

    func testInferredSyncedPurposeDoesNotSuppressSiblingReclaimRules() throws {
        let purposes = try classify([
            .directory("mystery", [.directory("Dropbox", [.file("data", 80)]),
                                    .directory("Cache", [.file("data", 20)])])
        ])
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery"), .synced)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/mystery/Cache/data"), .regenerableCache)
    }

    func testBareRepositoryIsRecognizedByObjectsRefsAndHeadAtAnyDepth() throws {
        let purposes = try classify([
            .directory("src", [.directory("bare", [.directory("objects", [.file("pack", 50)]),
                                                       .directory("refs", []), .file("HEAD", 1)])]),
            .directory("incomplete", [.directory("objects", []), .directory("refs", [])])
        ])
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/src/bare"), .git)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/src/bare/objects/pack"), .git)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/incomplete"), .other)
    }

    func testReclaimReasonIsInheritedThroughUnknownAndExplicitPurposeDirectories() throws {
        let purposes = try classify([
            .directory(".cache", [.directory("unknown", [.directory("src", [.file("data", 1)])])]),
            .directory("Sync", [.directory(".stversions", [.file("old", 1)])])
        ])
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.cache/unknown/src/data"), .regenerableCache)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/.cache/unknown/src/data"), .code)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/Sync/.stversions/old"), .syncHistory)
    }

    func testBuildAndDependencyDirectoriesRequireTheCorrespondingSiblingManifest() throws {
        let cases: [(String, String, SpaceMapReclaimReason)] = [
            ("target", "Cargo.toml", .buildOutput), (".build", "Package.swift", .buildOutput),
            ("build", "build.gradle", .buildOutput), ("build", "build.gradle.kts", .buildOutput),
            ("node_modules", "package.json", .reinstallableDependencies),
            ("Pods", "Podfile", .reinstallableDependencies),
            (".venv", "pyproject.toml", .reinstallableDependencies),
            ("venv", "requirements.txt", .reinstallableDependencies),
            (".venv", "setup.py", .reinstallableDependencies)
        ]
        for (directory, manifest, reason) in cases {
            let purposes = try classify([
                .directory("with", [.directory(directory.uppercased(), [.file("data", 1)]), .file(manifest.uppercased(), 1)]),
                .directory("without", [.directory(directory, [.file("data", 1)])])
            ])
            XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/with/" + directory.uppercased()), reason, directory)
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/without/" + directory), directory)
        }
    }

    func testLayersAndSnapshotsAreOnlyReclaimableInsideAgentWorkspaces() throws {
        let purposes = try classify([
            .directory(".microsandbox", [.directory("layers", [.file("layer", 1)]),
                                           .directory("snapshots", [.file("snapshot", 1)]),
                                           .directory("cache", [.directory("layers", [.file("layer", 1)])])]),
            .directory("Documents", [.directory("layers", [.file("personal", 1)]),
                                     .directory("snapshots", [.file("personal", 1)])])
        ])
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.microsandbox/layers"), .sandboxLayers)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.microsandbox/snapshots"), .snapshots)
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.microsandbox/cache/layers"), .regenerableCache)
        XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/Documents/layers"))
        XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/Documents/snapshots"))
    }

    func testAgentNamesIncludeCatalogRootsAndBothWorktreeNames() throws {
        let names = [".workbuddy", ".openclaw", ".continue", "worktrees", "sc-worktrees", ".codex", ".claude",
                     "Cursor", "Windsurf", "Claude", "Codex", "opencode"]
        let purposes = try classify(names.map { .directory($0, [.file("session", 1)]) })
        for name in names {
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/" + name + "/session"), .agentWorkspace, name)
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/" + name + "/session"), name)
        }
    }

    func testSteamEmulationAndPhotoLibraryPackagesAreMediaWithoutReclaimReasons() throws {
        let names = ["Steam", "SteamLibrary", "steamapps", "Emulation", "Movies", "Music", "Pictures", "Family.PhotosLibrary"]
        let purposes = try classify(names.map { .directory($0, [.directory("temp", [.file("personal", 1)])]) })
        for name in names {
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/" + name), .media, name)
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/" + name + "/temp"), .media, name)
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/" + name + "/temp"), name)
        }
    }

    func testMacDeveloperCachesAreReclaimableAndArchivesAndMobileBackupsAreProtected() throws {
        let purposes = try classify([
            .directory("Library", [.directory("Developer", [
                .directory("Xcode", [.directory("DerivedData", [.file("build", 1)]),
                                      .directory("iOS DeviceSupport", [.file("symbols", 1)]),
                                      .directory("watchOS DeviceSupport", [.file("symbols", 1)]),
                                      .directory("Archives", [.file("symbols", 1)])])
            ]), .directory("Application Support", [.directory("MobileSync", [.directory("Backup", [.file("only-copy", 1)])])])]),
            .directory("Developer", [.file("personal", 1)])
        ])
        let xcode = "/analysis/Library/Developer/Xcode/"
        XCTAssertEqual(purposes.purpose(atPath: xcode), .toolchain)
        XCTAssertEqual(purposes.reclaimReason(atPath: xcode + "DerivedData"), .buildOutput)
        XCTAssertEqual(purposes.reclaimReason(atPath: xcode + "iOS DeviceSupport"), .regenerableCache)
        XCTAssertEqual(purposes.reclaimReason(atPath: xcode + "watchOS DeviceSupport"), .regenerableCache)
        XCTAssertNil(purposes.reclaimReason(atPath: xcode + "Archives"))
        XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/Library/Application Support/MobileSync/Backup/only-copy"))
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/Developer"), .other)
    }

    func testProtectedArchivesAndBackupsStopEvenAnInheritedReclaimReason() throws {
        let purposes = try classify([
            .directory(".cache", [.directory("Xcode", [.directory("Archives", [.directory("cache", [.file("symbols", 1)])])]),
                                    .directory("MobileSync", [.directory("Backup", [.directory("cache", [.file("personal", 1)])])]),
                                    .directory("ordinary", [.directory("Archives", [.file("cached", 1)])])])
        ])
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.cache"), .regenerableCache)
        XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/.cache/Xcode/Archives/cache/symbols"))
        XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/.cache/MobileSync/Backup/cache/personal"))
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/.cache/ordinary/Archives/cached"), .regenerableCache)
    }

    func testLogsRequireApplicationSupportSiblingOutsideCatalog() throws {
        let purposes = try classify([
            .directory("Library", [.directory("Logs", [.file("diagnostic", 1)]), .directory("Application Support", [])]),
            .directory("src", [.directory("Logs", [.file("important", 1)])])
        ])
        XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/Library/Logs"), .logs)
        XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/src/Logs"))
    }

    func testCatalogUsesExactHomeRelativePathsAndDistinguishesLogsAndTemporaryFiles() throws {
        let purposes = try classify([
            .directory(".codex", [.directory("cache", [.file("data", 1)]), .directory("tmp", [.file("data", 1)]),
                                  .directory("sessions", [.file("personal", 1)])]),
            .directory(".claude", [.directory("logs", [.file("log", 1)]), .directory("debug", [.file("log", 1)]),
                                   .directory("telemetry", [.file("event", 1)])]),
            .directory(".CONTINUE", [.directory("INDEX", [.file("data", 1)])]),
            .directory(".workbuddy", [.directory("traces", [.file("log", 1)]), .directory("audit-log", [.file("audit", 1)])]),
            .directory("elsewhere", [.directory(".claude", [.directory("debug", [.file("personal", 1)])]),
                                       .directory(".continue", [.directory("index", [.file("personal", 1)])])])
        ])
        for (path, reason) in [(".codex/cache", SpaceMapReclaimReason.regenerableCache),
                               (".codex/tmp", .temporary), (".claude/logs", .logs), (".claude/debug", .logs),
                               (".claude/telemetry", .temporary), (".CONTINUE/INDEX", .regenerableCache),
                               (".workbuddy/traces", .logs)] {
            XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/" + path), reason, path)
        }
        for path in [".codex/sessions", ".workbuddy/audit-log", "elsewhere/.claude/debug", "elsewhere/.continue/index"] {
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/" + path), path)
        }
    }

    func testHomeChildrenAlsoGetTopLevelInferenceWhenScanningSlash() throws {
        let index = SpaceMapMemoryIndex.make(rootPath: "/", children: [
            .directory("Users", [.directory("tester", [
                .directory("world", [.directory("a", [.directory("b", [.directory(".git", [.file("pack", 9)])])])]),
                .directory("mystery", [.file("data", 1)])
            ])])
        ])
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/Users/tester"))
        XCTAssertEqual(purposes.purpose(atPath: "/Users/tester/world"), .git)
        XCTAssertEqual(purposes.purpose(atPath: "/Users/tester/mystery"), .other)
    }

    func testRemovedPlatformAndPersonalNamesHaveNoRules() throws {
        let names = ["temp", "$recycle.bin", "npm-cache", "v3-cache", "inetcache", "d3dscache",
                     "dxcache", "glcache", "crashdumps", "iclouddrive", ".herdr", ".pi", ".omp"]
        let purposes = try classify(names.map { .directory($0, [.file("data", 1)]) })
        for name in names {
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/" + name), .other, name)
            XCTAssertNil(purposes.reclaimReason(atPath: "/analysis/" + name), name)
        }
    }

    func testMacSyncPackageStoreTrashTemporaryAndBuildNames() throws {
        let cases: [(String, SpaceMapPurpose, SpaceMapReclaimReason?)] = [
            ("Mobile Documents", .synced, nil), ("CloudStorage", .synced, nil),
            ("OneDrive - Work", .synced, nil), ("Dropbox (Work)", .synced, nil),
            (".pnpm-store", .toolchain, .packageStore), (".Trash", .cache, .trash),
            ("tmp", .cache, .temporary), (".tmp", .cache, .temporary),
            ("__pycache__", .cache, .buildOutput), (".pytest_cache", .other, .buildOutput)
        ]
        let purposes = try classify(cases.map { .directory($0.0, [.file("data", 1)]) })
        for (name, purpose, reason) in cases {
            XCTAssertEqual(purposes.purpose(atPath: "/analysis/" + name), purpose, name)
            XCTAssertEqual(purposes.reclaimReason(atPath: "/analysis/" + name), reason, name)
        }
    }

    func testExternalVolumeTrashesAndItsUserDirectoryInheritTrash() throws {
        let root = "/Volumes/External"
        let index = SpaceMapMemoryIndex.make(rootPath: root, children: [
            .directory(".Trashes", [.directory("501", [.file("deleted", 1)])])
        ])
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/Users/tester"))
        for path in [".Trashes", ".Trashes/501", ".Trashes/501/deleted"] {
            XCTAssertEqual(purposes.purpose(atPath: root + "/" + path), .cache, path)
            XCTAssertEqual(purposes.reclaimReason(atPath: root + "/" + path), .trash, path)
        }
    }

    func testSparseMapDoesNotStoreFilesOrUnrecognizedInheritingDirectories() throws {
        let purposes = try classify([
            .directory("src", (0..<2_048).map { .file("file-\($0)", 1) }
                + [.directory("unknown", [.file("cache", 1)])]),
            .directory("mystery", [.file(".git", 1)]), .file(".codex", 1)
        ])
        XCTAssertEqual(purposes.explicitDirectoryCount, 1)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/src/unknown/cache"), .code)
        XCTAssertEqual(purposes.purpose(atPath: "/analysis/mystery/.git"), .other)
        XCTAssertEqual(purposes.purpose(atPath: "/outside/src"), .other)
    }

    func testCancellationBeforeAndDuringDirectoryClassificationReturnsNil() {
        let index = SpaceMapMemoryIndex.make(children: (0..<2_050).map { .directory("unknown-\($0)", []) })
        XCTAssertNil(SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis", isCancelled: { true }))
        var checks = 0
        let purposes = SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis") {
            checks += 1
            return checks == 2
        }
        XCTAssertNil(purposes)
        XCTAssertEqual(checks, 2)
    }

    @MainActor
    func testLegendAndBothLanguagesHaveCompleteNonemptyTitles() {
        XCTAssertEqual(SpaceMapPurpose.legend, [.code, .agentWorkspace, .toolchain, .synced, .git, .media, .documents, .cache])
        XCTAssertEqual(Set(SpaceMapPurpose.legend).count, 8)
        for language in [AppLanguage.zhHans, .english] {
            withLanguage(language) {
                let expected = language == .zhHans
                    ? ["代码", "AI 工作区", "工具链", "同步盘", "版本库", "媒体", "文档", "缓存", "其他"]
                    : ["Code", "AI Workspaces", "Toolchains", "Synced", "Git", "Media", "Documents", "Caches", "Other"]
                XCTAssertEqual(SpaceMapPurpose.allCases.map(\.title), expected)
                XCTAssertTrue(SpaceMapReclaimReason.allCases.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
    }

    private func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        let preferences = TestVolatilePreferences()
        preferences.set(defaults.string(forKey: L10n.languageDefaultsKey) ?? language.rawValue,
            forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
        try body()
    }

    private func classify(_ children: [SpaceMapMemoryNode]) throws -> SpaceMapPurposeMap {
        try XCTUnwrap(SpaceMapPurposeClassifier.classify(
            index: SpaceMapMemoryIndex.make(children: children), homePath: "/analysis"
        ))
    }
}
