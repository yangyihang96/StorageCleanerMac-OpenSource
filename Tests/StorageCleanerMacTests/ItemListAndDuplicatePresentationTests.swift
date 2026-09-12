import XCTest
@testable import StorageCleanerMac

final class ItemListAndDuplicatePresentationTests: XCTestCase {
    func testItemListSelectionFallsBackToFirstVisibleItemWhenCurrentItemDisappears() {
        XCTAssertEqual(
            ItemListSelectionResolver.resolvedSelectionID(
                currentSelectionID: "removed",
                visibleItemIDs: ["first", "second"]
            ),
            "first"
        )
    }

    func testItemListSelectionPreservesVisibleSelectionAndClearsWhenListBecomesEmpty() {
        XCTAssertEqual(
            ItemListSelectionResolver.resolvedSelectionID(
                currentSelectionID: "second",
                visibleItemIDs: ["first", "second"]
            ),
            "second"
        )
        XCTAssertNil(
            ItemListSelectionResolver.resolvedSelectionID(
                currentSelectionID: "second",
                visibleItemIDs: []
            )
        )
    }

    func testCleanupWorkspacesKeepBothPanesReadableAtNarrowMainWindowWidth() {
        for filter in ReviewFilter.cleanupWorkspaceCases {
            guard case let .sideBySide(listWidth, detailWidth) =
                ItemListResponsiveLayout.mode(availableWidth: 794) else {
                return XCTFail("\(filter.title) should keep the shared two-pane layout at 794 pt")
            }

            XCTAssertGreaterThanOrEqual(
                listWidth,
                ItemListResponsiveLayout.minimumListWidth,
                filter.title
            )
            XCTAssertGreaterThanOrEqual(
                detailWidth,
                ItemListResponsiveLayout.minimumDetailWidth,
                filter.title
            )
            XCTAssertLessThanOrEqual(
                listWidth + ItemListResponsiveLayout.dividerWidth + detailWidth,
                794,
                filter.title
            )
        }
    }

    func testCleanupWorkspaceFallsBackToStackedLayoutBeforeEitherPaneCanOverlap() {
        let compressedWidth = ItemListResponsiveLayout.minimumListWidth
            + ItemListResponsiveLayout.minimumDetailWidth
            + ItemListResponsiveLayout.dividerWidth
            - 1

        XCTAssertEqual(
            ItemListResponsiveLayout.mode(availableWidth: compressedWidth),
            .stacked
        )
    }

    func testCleanupWorkspaceUsesOneResponsiveEmptyStateAndWrapsStatusMetrics() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ItemListView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("if currentItems.isEmpty {"))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("LazyVGrid("))
        XCTAssertTrue(source.contains("details = [item.kind, size, item.path]"))
    }

    func testSafeCleanupHidesCrossTierMetricsAndCompactsHistoryActions() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ItemListView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("filter != .green"))
        XCTAssertTrue(source.contains("L10n.text(\"可清理项目\", \"Cleanable Items\")"))
        XCTAssertTrue(source.contains("L10n.text(\"选择清理项目\", \"Choose Cleanup Items\")"))
        XCTAssertTrue(source.contains("L10n.text(\"清理记录操作\", \"Cleanup History Actions\")"))
    }

    func testItemDetailHidesDuplicateAndEmptyMetadata() {
        let item = makeDuplicateItem(
            id: "cache",
            title: "Cache",
            path: "/Users/test/Library/Caches/App",
            kind: "Cache",
            groupTitle: "Cache",
            requiresClose: "None"
        )

        XCTAssertEqual(
            ItemDetailPresentation.fields(for: item).map(\.id),
            ["type", "reason", "risk"]
        )
    }

    func testItemDetailKeepsDistinctSourceAndRealCloseRequirement() {
        let item = makeDuplicateItem(
            id: "browser-cache",
            title: "Browser Cache",
            path: "/Users/test/Library/Caches/Browser",
            kind: "Cache",
            groupTitle: "Browser",
            requiresClose: "Safari"
        )

        XCTAssertEqual(
            ItemDetailPresentation.fields(for: item).map(\.id),
            ["type", "source", "reason", "risk", "close"]
        )
    }

    func testDuplicateSearchKeepsCompleteGroupWhenOneMemberPathMatches() throws {
        let projectCopy = makeDuplicateItem(
            id: "project-copy",
            title: "Report.pdf",
            path: "/Users/test/Documents/Project/Report.pdf"
        )
        let archiveCopy = makeDuplicateItem(
            id: "archive-copy",
            title: "Report.pdf",
            path: "/Users/test/Documents/Archive/Report.pdf"
        )

        let groups = DuplicateFilesPresenter.groups(
            from: [archiveCopy, projectCopy],
            matching: "Project"
        )

        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.items.map(\.id), ["archive-copy", "project-copy"])
    }

    func testDuplicateSearchDoesNotPromoteSingletonsIntoDuplicateGroups() {
        let singleton = makeDuplicateItem(
            id: "single",
            title: "Only.pdf",
            path: "/Users/test/Documents/Project/Only.pdf"
        )

        XCTAssertTrue(
            DuplicateFilesPresenter.groups(from: [singleton], matching: "Project").isEmpty
        )
    }

    func testConfirmedContentGroupCanContainDifferentFileNamesWithoutClaimingPhysicalSavings() throws {
        let first = makeDuplicateItem(
            id: "first",
            title: "Original.mov",
            path: "/Users/test/Documents/Original.mov",
            duplicateGroupID: "sha256:fixture"
        )
        let second = makeDuplicateItem(
            id: "second",
            title: "Copy-renamed.mov",
            path: "/Users/test/Documents/Copy-renamed.mov",
            duplicateGroupID: "sha256:fixture"
        )

        let group = try XCTUnwrap(DuplicateFilesPresenter.groups(from: [first, second]).first)
        XCTAssertEqual(group.items.count, 2)
        XCTAssertTrue(group.isContentConfirmed)
        XCTAssertNil(group.physicalReclaimableBytes)
        XCTAssertEqual(group.logicalDuplicateBytes, 1_024)
    }

    func testManualCandidateRemainsSeparateFromExactResultsAndNeverClaimsConfirmation() throws {
        let first = makeDuplicateItem(
            id: "candidate-first",
            title: "Report.pdf",
            path: "/Users/test/Documents/One/Report.pdf",
            duplicateGroupID: "candidate|report|1024|pdf",
            duplicateMatchKind: DuplicateFileCandidateGroup.Rule.sameName.rawValue
        )
        let second = makeDuplicateItem(
            id: "candidate-second",
            title: "Report.pdf",
            path: "/Users/test/Documents/Two/Report.pdf",
            duplicateGroupID: "candidate|report|1024|pdf",
            duplicateMatchKind: DuplicateFileCandidateGroup.Rule.sameName.rawValue
        )

        let candidate = try XCTUnwrap(DuplicateFilesPresenter.groups(
            from: [first, second],
            filter: .candidates
        ).first)
        XCTAssertFalse(candidate.isContentConfirmed)
        XCTAssertNil(candidate.physicalReclaimableBytes)
        XCTAssertTrue(DuplicateFilesPresenter.groups(
            from: [first, second],
            filter: .exact
        ).isEmpty)
        XCTAssertEqual(candidate.candidateRule, .sameName)
        XCTAssertEqual(DuplicateFilesPresenter.groups(
            from: [first, second],
            filter: .sameName
        ).count, 1)
        XCTAssertTrue(DuplicateFilesPresenter.groups(
            from: [first, second],
            filter: .sameSize
        ).isEmpty)
    }

    func testSimilarImageCandidatesHaveTheirOwnFilterAndRemainUnconfirmed() throws {
        let first = makeDuplicateItem(
            id: "similar-first",
            title: "Photo.png",
            path: "/Users/test/Pictures/Photo.png",
            duplicateGroupID: "candidate|similarImage|fixture",
            duplicateMatchKind: DuplicateFileCandidateGroup.Rule.similarImage.rawValue
        )
        let second = makeDuplicateItem(
            id: "similar-second",
            title: "Photo-edited.jpg",
            path: "/Users/test/Downloads/Photo-edited.jpg",
            duplicateGroupID: "candidate|similarImage|fixture",
            duplicateMatchKind: DuplicateFileCandidateGroup.Rule.similarImage.rawValue
        )

        let group = try XCTUnwrap(DuplicateFilesPresenter.groups(
            from: [first, second],
            filter: .similarImage
        ).first)
        XCTAssertEqual(group.candidateRule, .similarImage)
        XCTAssertFalse(group.isContentConfirmed)
        XCTAssertNil(group.physicalReclaimableBytes)
        XCTAssertTrue(DuplicateFilesPresenter.groups(
            from: [first, second],
            filter: .exact
        ).isEmpty)
    }

    @MainActor
    func testDuplicateWorkspaceRestoresFiltersAndScopesButNotDestructiveSelection() throws {
        let suite = "duplicate-workspace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DuplicateFilesStore(defaults: defaults)
        first.searchText = "invoice"
        first.resultFilter = .exact
        first.resultSort = .name
        first.addCustomRoot("/Users/test/Projects")
        first.addExternalRoot("/Volumes/Archive")
        first.setCandidateRule(.sameType, enabled: false)

        let restored = DuplicateFilesStore(defaults: defaults)
        XCTAssertEqual(restored.searchText, "invoice")
        XCTAssertEqual(restored.resultFilter, .exact)
        XCTAssertEqual(restored.resultSort, .name)
        XCTAssertEqual(restored.customRootPaths, ["/Users/test/Projects"])
        XCTAssertEqual(restored.externalRootPaths, ["/Volumes/Archive"])
        XCTAssertEqual(restored.candidateRules, [.sameName, .sameSize, .similarImage])
        XCTAssertTrue(restored.selectedItemIDs.isEmpty)
    }

    @MainActor
    func testDuplicateWorkspaceMigratesSimilarImageRuleOnceAndPreservesOptOut() throws {
        let suite = "duplicate-workspace-rules-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            [
                DuplicateFileCandidateGroup.Rule.sameName.rawValue,
                DuplicateFileCandidateGroup.Rule.sameSize.rawValue,
            ],
            forKey: "duplicate-files.candidate-rules"
        )

        let migrated = DuplicateFilesStore(defaults: defaults)
        XCTAssertEqual(migrated.candidateRules, [.sameName, .sameSize, .similarImage])
        migrated.setCandidateRule(.similarImage, enabled: false)

        XCTAssertEqual(
            DuplicateFilesStore(defaults: defaults).candidateRules,
            [.sameName, .sameSize]
        )
    }

    @MainActor
    func testDuplicateSelectionKeepsOneCopyAndRejectsManualCandidates() {
        let digest = Data(repeating: 0xA1, count: 32).base64EncodedString()
        let first = makeDuplicateItem(
            id: "exact-first",
            title: "A.bin",
            path: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/A.bin").path,
            duplicateGroupID: digest
        )
        let second = makeDuplicateItem(
            id: "exact-second",
            title: "B.bin",
            path: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/B.bin").path,
            duplicateGroupID: digest
        )
        let candidate = makeDuplicateItem(
            id: "candidate",
            title: "C.bin",
            path: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/C.bin").path,
            duplicateGroupID: "candidate|c|1024|bin",
            duplicateMatchKind: DuplicateFileCandidateGroup.Rule.sameNameSizeAndType.rawValue
        )
        let store = DuplicateFilesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        store.setSelected(true, item: first, allItems: [first, second, candidate])
        XCTAssertEqual(store.selectedItemIDs, Set([first.id]))
        store.setSelected(true, item: second, allItems: [first, second, candidate])
        XCTAssertEqual(store.selectedItemIDs, Set([first.id]))
        XCTAssertNotNil(store.selectionMessage)
        store.dismissSelectionMessage()
        store.setSelected(true, item: candidate, allItems: [first, second, candidate])
        XCTAssertFalse(store.selectedItemIDs.contains(candidate.id))
        XCTAssertNotNil(store.selectionMessage)
    }

    func testDuplicateRouteIsIndependentFromFileAnalysisRoute() {
        XCTAssertEqual(ReviewFilter.largeFiles.sidebarGroupAnchor, .largeFiles)
        XCTAssertEqual(ReviewFilter.duplicates.sidebarGroupAnchor, .duplicates)
        XCTAssertEqual(ReviewFilter.largeFiles.sidebarDestination, .largeFiles)
        XCTAssertEqual(ReviewFilter.duplicates.sidebarDestination, .duplicates)
    }

    func testDuplicateLandingKeepsScopeCopyShortWhileTrustTextOwnsSafetyDetails() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private var duplicateScanScopeDetail"))
        let end = try XCTUnwrap(
            source.range(of: "private var scanButtonSystemImage", range: start.upperBound..<source.endIndex)
        )
        let detail = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(detail.contains("扫描常用用户文件夹和你明确选择的位置。"))
        XCTAssertTrue(detail.contains("扫描用户数据区和你明确选择的卷。"))
        XCTAssertFalse(detail.contains("coverageDescription"))
    }

    func testDuplicateLocationCardsKeepScopeSelectionAndNativeActions() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private var duplicateScanAccessory"))
        let end = try XCTUnwrap(
            source.range(of: "private var duplicateToolbarActions", range: start.upperBound..<source.endIndex)
        )
        let accessory = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(accessory.contains("duplicateLocationButton(externalVolume: false)"))
        XCTAssertTrue(accessory.contains("duplicateLocationButton(externalVolume: true)"))
        XCTAssertTrue(accessory.contains("chooseDuplicateRoot(externalVolume: externalVolume)"))
        XCTAssertTrue(accessory.contains("workspace.scanScope = scope"))
        XCTAssertTrue(accessory.contains(".accessibilityAddTraits(workspace.scanScope == scope"))
        XCTAssertTrue(accessory.contains("minHeight: GoldenLandingMetrics.locationButtonHeight"))
        XCTAssertTrue(accessory.contains("ForEach(workspace.configuredAdditionalRoots"))
        XCTAssertTrue(accessory.contains("workspace.removeExternalRoot(path)"))
        XCTAssertTrue(accessory.contains("workspace.removeCustomRoot(path)"))
        XCTAssertFalse(accessory.contains("Label(L10n.text(\"添加文件夹\""))
        XCTAssertFalse(accessory.contains("Label(L10n.text(\"选择外接卷\""))
        XCTAssertTrue(source.contains("workspace.hasScanned ? \"arrow.clockwise\" : \"viewfinder\""))
    }

    func testDuplicateCleanupConfirmationUsesOnlyPreflightReadyFrozenPaths() throws {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let root = home.appendingPathComponent("Documents", isDirectory: true)
        let first = root.appendingPathComponent("A/Report.pdf")
        let second = root.appendingPathComponent("B/Report.pdf")
        let retained = root.appendingPathComponent("Original/Report.pdf")
        let retainedCopy = VerifiedDuplicateRetainedCopy(
            url: retained,
            expectedSnapshot: duplicateSnapshot(url: retained, inode: 103)
        )
        let bundle = try VerifiedDuplicateCleanPlanBuilder.makePlan(
            requests: [
                VerifiedDuplicatePlanRequest(
                    sourceURL: first,
                    allowedRootURL: root,
                    expectedSnapshot: duplicateSnapshot(url: first, inode: 101),
                    groupID: "sha256:report",
                    digest: Data(repeating: 0xA1, count: 32),
                    retainedCopies: [retainedCopy]
                ),
                VerifiedDuplicatePlanRequest(
                    sourceURL: second,
                    allowedRootURL: root,
                    expectedSnapshot: duplicateSnapshot(url: second, inode: 102),
                    groupID: "sha256:report",
                    digest: Data(repeating: 0xA1, count: 32),
                    retainedCopies: [retainedCopy]
                )
            ],
            disposition: .quarantine,
            userHomeURL: home
        )
        let firstItem = try XCTUnwrap(bundle.plan.items.first { $0.sourceURL == first })
        let secondItem = try XCTUnwrap(bundle.plan.items.first { $0.sourceURL == second })
        let preflight = CleanPreflightReport(
            planID: bundle.plan.id,
            checkedAt: Date(),
            items: [
                CleanPreflightItem(planItemID: firstItem.id, status: .ready),
                CleanPreflightItem(planItemID: secondItem.id, status: .skipped(.identityChanged))
            ],
            failure: nil
        )

        let presentation = try XCTUnwrap(DuplicateCleanupConfirmationPresentation(
            plan: bundle.plan,
            preflight: preflight
        ))
        let group = try XCTUnwrap(presentation.groups.first)

        XCTAssertEqual(presentation.disposition, .quarantine)
        XCTAssertEqual(presentation.readyCount, 1)
        XCTAssertEqual(presentation.skippedCount, 1)
        XCTAssertEqual(presentation.groups.count, 1)
        XCTAssertEqual(group.retainedPaths, [retained.path])
        XCTAssertEqual(group.destinationPaths, [first.path])
        XCTAssertFalse(group.destinationPaths.contains(second.path))
    }

    func testDuplicateCleanupConfirmationSheetKeepsDesktopSafetyContracts() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("DuplicateCleanupConfirmationSheet("))
        XCTAssertTrue(source.contains(".frame(minHeight: 220, maxHeight: 420)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(source.contains("重复文件确认明细"))
    }

    private func makeDuplicateItem(
        id: String,
        title: String,
        path: String,
        sizeBytes: Int64 = 1_024,
        kind: String = "PDF",
        groupTitle: String = "Duplicates",
        requiresClose: String = "None",
        duplicateGroupID: String? = nil,
        duplicateMatchKind: String? = nil
    ) -> StorageItem {
        StorageItem(
            id: id,
            title: title,
            path: path,
            sourceID: "duplicate_files",
            groupTitle: groupTitle,
            sizeBytes: sizeBytes,
            tier: .yellow,
            kind: kind,
            reason: "Same name and size",
            recommendation: "Review both copies",
            risk: "Review required",
            requiresClose: requiresClose,
            trashPaths: [],
            openPath: path,
            duplicateGroupID: duplicateGroupID,
            duplicateMatchKind: duplicateMatchKind
                ?? (duplicateGroupID == nil ? nil : DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue),
            status: .available
        )
    }

    private func duplicateSnapshot(url: URL, inode: UInt64) -> FileSnapshot {
        FileSnapshot(
            identity: FileIdentity(
                deviceID: 51,
                inode: inode,
                entryKind: .regularFile,
                creationTimeNanoseconds: Int64(inode)
            ),
            standardizedPath: url.path,
            volumeIdentifier: "duplicate-confirmation-fixture",
            logicalSizeBytes: 4_096,
            allocatedSizeBytes: 4_096,
            modificationTimeNanoseconds: 100,
            isWritableVolume: true,
            isCloudItem: false,
            isCloudPlaceholder: false,
            hasSymbolicLinkComponent: false
        )
    }
}
