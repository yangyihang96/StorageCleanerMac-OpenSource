import XCTest
@testable import StorageCleanerMac

final class StartupItemManagementTests: XCTestCase {
    typealias Domain = StartupItemsDomain

    func testCapabilityMatrixKeepsHardwareHelperOutOfStartupManagement() throws {
        XCTAssertTrue(Domain.StartupManagementCapability.nonSandboxDirect.canManageCurrentUserLaunchAgents)
        XCTAssertFalse(Domain.StartupManagementCapability.nonSandboxDirect.canManageSystemLaunchItems)
        XCTAssertFalse(Domain.StartupManagementCapability.nonSandboxDirect.hasPrivilegedHelper)
        XCTAssertFalse(Domain.StartupManagementCapability.sandboxRestricted.canManageCurrentUserLaunchAgents)
        XCTAssertFalse(Domain.StartupManagementCapability.sandboxRestricted.canInspectStandardLaunchdDirectories)
        XCTAssertFalse(Domain.StartupManagementCapability.sandboxRestricted.hasPrivilegedHelper)
    }

    func testCapabilityResolutionUsesSandboxEntitlementAndFailsClosed() {
        XCTAssertEqual(
            Domain.StartupManagementCapability.resolving(appSandboxEntitlement: true).distributionProfile,
            .sandboxRestricted
        )
        XCTAssertEqual(
            Domain.StartupManagementCapability.resolving(appSandboxEntitlement: false).distributionProfile,
            .nonSandboxDirect
        )
        XCTAssertEqual(
            Domain.StartupManagementCapability.resolving(appSandboxEntitlement: nil).distributionProfile,
            .sandboxRestricted
        )
    }

    func testHardwareHelperProtocolDoesNotAcceptStartupItemOperations() {
        XCTAssertNil(FanControlHelperRequest.Operation(rawValue: "manageStartupItem"))
    }

    func testLiveFactoryIsConstructionOnly() {
        let manager = Domain.UserLaunchAgentManager.live(
            homeDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertNotNil(manager)
    }

    func testCapabilityResolverManagesVerifiedUserLaunchAgentWithoutRequiringAppAttribution() throws {
        let fixture = try Fixture()
        let direct = fixture.resolver.capability(for: fixture.candidate())
        XCTAssertTrue(direct.canEnableDirectly)
        XCTAssertTrue(direct.canDisableDirectly)
        XCTAssertFalse(direct.requiresAdministrator)

        var lowConfidence = fixture.candidate()
        lowConfidence.attribution = Domain.Attribution(
            applicationBundleIdentifier: nil,
            applicationURL: nil,
            applicationName: nil,
            developerName: nil,
            teamIdentifier: nil,
            designatedRequirement: nil,
            evidence: [Domain.AttributionEvidence(
                kind: .labelHint,
                value: "example",
                confidence: .low
            )]
        )
        let low = fixture.resolver.capability(for: lowConfidence)
        XCTAssertTrue(low.canEnableDirectly)
        XCTAssertTrue(low.canDisableDirectly)
        XCTAssertFalse(low.isReadOnly)

        var managed = fixture.candidate()
        managed.kind = .managedItem
        managed.scope = .managed
        let managedCapability = fixture.resolver.capability(for: managed)
        XCTAssertTrue(managedCapability.isManaged)
        XCTAssertTrue(managedCapability.canOpenSystemSettings)

        var system = fixture.candidate()
        system.kind = .systemLaunchDaemon
        system.scope = .system
        let protected = fixture.resolver.capability(for: system)
        XCTAssertTrue(protected.isReadOnly)
        XCTAssertFalse(protected.canOpenSystemSettings)

        var global = fixture.candidate()
        global.kind = .launchDaemon
        global.scope = .system
        let helperUnavailable = fixture.resolver.capability(for: global)
        XCTAssertTrue(helperUnavailable.requiresAdministrator)
        XCTAssertFalse(helperUnavailable.canDisableDirectly)
        XCTAssertTrue(helperUnavailable.canOpenSystemSettings)

        var verifiedGlobal = fixture.candidate()
        verifiedGlobal.kind = .globalLaunchAgent
        verifiedGlobal.scope = .allUsers
        verifiedGlobal.plistURL = URL(
            fileURLWithPath: "/Library/LaunchAgents/com.example.agent.plist"
        )
        verifiedGlobal.state.management = .requiresAdministrator
        let administratorCapability = fixture.resolver.capability(for: verifiedGlobal)
        XCTAssertTrue(administratorCapability.requiresAdministrator)
        XCTAssertFalse(administratorCapability.canEnableDirectly)
        XCTAssertFalse(administratorCapability.canDisableDirectly)
        XCTAssertTrue(administratorCapability.isReadOnly)

        let sandbox = Domain.StartupCapabilityResolver(
            platform: .sandboxRestricted,
            currentUserID: getuid(),
            homeDirectory: fixture.root
        ).capability(for: fixture.candidate())
        XCTAssertFalse(sandbox.canDisableDirectly)
        XCTAssertTrue(sandbox.canOpenSystemSettings)

        var openAtLogin = fixture.candidate()
        openAtLogin.kind = .openAtLogin
        let openAtLoginCapability = fixture.resolver.capability(for: openAtLogin)
        XCTAssertFalse(openAtLoginCapability.canDisableDirectly)
        XCTAssertTrue(openAtLoginCapability.canOpenSystemSettings)
    }

    func testWeakBundleAttributionDoesNotBlockVerifiedExecutableManagement() throws {
        let fixture = try Fixture()
        var candidate = fixture.candidate()
        candidate.attribution?.evidence = [Domain.AttributionEvidence(
            kind: .associatedBundleIdentifier,
            value: "com.example.app",
            confidence: .high
        )]

        let capability = fixture.resolver.capability(for: candidate)

        XCTAssertTrue(capability.canEnableDirectly)
        XCTAssertTrue(capability.canDisableDirectly)
        XCTAssertTrue(capability.canStopCurrentSession)

        XCTAssertNoThrow(try fixture.planBuilder.plan(for: candidate, operation: .enable))
        XCTAssertNoThrow(try fixture.planBuilder.plan(for: candidate, operation: .disable))
        XCTAssertNoThrow(try fixture.planBuilder.plan(for: candidate, operation: .stopCurrentSession))
    }

    func testManagerCannotPreviewEnableWhenExecutableIdentityIsInvalid() async throws {
        let fixture = try Fixture()
        var candidate = fixture.candidate(state: .disabled)
        candidate.diagnosticEvidence = ["signature-invalid"]
        let runner = RecordingRunner(responses: [])
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: QueueStateResolver(states: []),
            undoStore: MemoryUndoStore(),
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )

        do {
            _ = try await manager.preview(candidate: candidate, operation: .enable)
            XCTFail("Expected enable preview to fail closed")
        } catch let error as Domain.StartupManagementError {
            XCTAssertEqual(
                error,
                .unsupported("readOnly(reason: \"startup-item-identity-not-verified\")")
            )
        }
        let invocations = await runner.invocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testMatchingNonemptyParentAndHelperTeamAllowsEnable() throws {
        let fixture = try Fixture()
        var candidate = fixture.candidate()
        candidate.attribution?.evidence = [Domain.AttributionEvidence(
            kind: .associatedBundleIdentifier,
            value: "com.example.app",
            confidence: .high
        )]
        candidate.diagnosticEvidence.append("parent-helper-team-identifier-match")

        XCTAssertTrue(fixture.resolver.capability(for: candidate).canEnableDirectly)
    }

    func testCapabilityResolverFailsClosedWithoutVerifiedIdentity() throws {
        let fixture = try Fixture()
        var unsigned = fixture.candidate()
        unsigned.diagnosticEvidence = ["unsigned-executable"]
        XCTAssertFalse(fixture.resolver.capability(for: unsigned).canDisableDirectly)

        var mismatchedTeam = fixture.candidate()
        mismatchedTeam.diagnosticEvidence = ["valid-code-signature", "team-identifier-mismatch"]
        XCTAssertFalse(fixture.resolver.capability(for: mismatchedTeam).canDisableDirectly)

        var unsafePath = fixture.candidate()
        unsafePath.diagnosticEvidence = ["valid-code-signature", "world-writable"]
        XCTAssertFalse(fixture.resolver.capability(for: unsafePath).canDisableDirectly)

        var nonExecutable = fixture.candidate()
        nonExecutable.diagnosticEvidence = ["valid-code-signature", "target-not-executable"]
        XCTAssertFalse(fixture.resolver.capability(for: nonExecutable).canDisableDirectly)
    }

    func testDisablePlanUsesExactUserDomainAndBootoutBeforeDisable() throws {
        let fixture = try Fixture()
        let plan = try fixture.planBuilder.plan(
            for: fixture.candidate(state: .loadedEnabled),
            operation: .disable
        )

        XCTAssertEqual(plan.domain, "gui/\(getuid())")
        XCTAssertEqual(plan.serviceTarget, "gui/\(getuid())/com.example.agent")
        XCTAssertEqual(plan.commands.map(\.executableURL.path), ["/bin/launchctl", "/bin/launchctl"])
        XCTAssertEqual(plan.commands.map(\.arguments), [
            ["bootout", "gui/\(getuid())/com.example.agent"],
            ["disable", "gui/\(getuid())/com.example.agent"]
        ])
    }

    func testEnableAndStopPlansNeverModifyPlist() throws {
        let fixture = try Fixture()
        let enable = try fixture.planBuilder.plan(
            for: fixture.candidate(state: .disabled),
            operation: .enable
        )
        XCTAssertEqual(enable.commands.map(\.arguments), [
            ["enable", "gui/\(getuid())/com.example.agent"],
            ["bootstrap", "gui/\(getuid())", fixture.plistURL.path]
        ])

        let stop = try fixture.planBuilder.plan(
            for: fixture.candidate(state: .loadedEnabled),
            operation: .stopCurrentSession
        )
        XCTAssertEqual(stop.commands.map(\.arguments), [
            ["bootout", "gui/\(getuid())/com.example.agent"]
        ])
        XCTAssertFalse(stop.commands.flatMap(\.arguments).contains("disable"))
    }

    func testPlanRejectsOutsideSymlinkAndWorldWritablePlists() throws {
        let fixture = try Fixture()
        let outside = fixture.root.appendingPathComponent("outside.plist")
        try Data("{}".utf8).write(to: outside)
        var outsideCandidate = fixture.candidate()
        outsideCandidate.plistURL = outside
        XCTAssertThrowsError(try fixture.planBuilder.plan(for: outsideCandidate, operation: .disable)) {
            XCTAssertEqual($0 as? Domain.StartupManagementError, .unsupported("readOnly(reason: \"launch-agent-outside-current-user-domain\")"))
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fixture.plistURL.path)
        XCTAssertThrowsError(try fixture.planBuilder.plan(for: fixture.candidate(), operation: .disable)) {
            XCTAssertEqual($0 as? Domain.StartupManagementError, .unsafePlistPermissions)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.plistURL.path)
        let target = fixture.root.appendingPathComponent("target.plist")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.removeItem(at: fixture.plistURL)
        try FileManager.default.createSymbolicLink(at: fixture.plistURL, withDestinationURL: target)
        XCTAssertThrowsError(try fixture.planBuilder.plan(for: fixture.candidate(), operation: .disable))
    }

    func testPlanReReadsPlistAndRejectsChangedLabel() throws {
        let fixture = try Fixture()
        let replaced = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.example.replaced",
                "Program": "/usr/bin/true",
            ],
            format: .xml,
            options: 0
        )
        try replaced.write(to: fixture.plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.plistURL.path)

        XCTAssertThrowsError(try fixture.planBuilder.plan(for: fixture.candidate(), operation: .disable)) {
            XCTAssertEqual($0 as? Domain.StartupManagementError, .invalidLabel)
        }
    }

    func testPlanRejectsSameLabelWithChangedExecutableConfiguration() throws {
        let fixture = try Fixture()
        let replaced = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.example.agent",
                "ProgramArguments": ["/usr/bin/false", "--changed"],
            ],
            format: .xml,
            options: 0
        )
        try replaced.write(to: fixture.plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.plistURL.path)

        XCTAssertThrowsError(try fixture.planBuilder.plan(for: fixture.candidate(), operation: .disable)) {
            XCTAssertEqual($0 as? Domain.StartupManagementError, .startupConfigurationChanged)
        }
    }

    func testPerformRejectsPlistDigestChangeAfterPreview() async throws {
        let fixture = try Fixture()
        let runner = RecordingRunner(responses: [])
        let states = QueueStateResolver(states: [.loadedEnabled])
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: states,
            undoStore: MemoryUndoStore(),
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate()
        let preview = try await manager.preview(candidate: candidate, operation: .disable)
        let changed = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.example.agent",
                "Program": "/usr/bin/true",
                "EnvironmentVariables": ["EXAMPLE": "changed-after-preview"],
            ],
            format: .xml,
            options: 0
        )
        try changed.write(to: fixture.plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.plistURL.path)

        do {
            _ = try await manager.perform(preview, candidate: candidate)
            XCTFail("Expected changed plist digest to be rejected")
        } catch let error as Domain.StartupManagementError {
            XCTAssertEqual(error, .startupConfigurationChanged)
        }
        let invocations = await runner.invocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testPerformRejectsStateChangeAfterPreviewWithoutCreatingUndo() async throws {
        let fixture = try Fixture()
        let runner = RecordingRunner(responses: [])
        let states = QueueStateResolver(states: [.disabled])
        let undo = MemoryUndoStore()
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: states,
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate(state: .loadedEnabled)
        let preview = try await manager.preview(candidate: candidate, operation: .disable)

        do {
            _ = try await manager.perform(preview, candidate: candidate)
            XCTFail("Expected changed launchd state to be rejected")
        } catch let error as Domain.StartupManagementError {
            XCTAssertEqual(error, .startupStateChanged)
        }
        let invocations = await runner.invocations()
        let records = try await undo.allRecords()
        XCTAssertTrue(invocations.isEmpty)
        XCTAssertTrue(records.isEmpty)
    }

    func testFailureBeforeUndoCreationNeverExposesAnOlderRecordAsRecovery() async throws {
        let fixture = try Fixture()
        let undo = MemoryUndoStore()
        let oldRecord = Domain.StartupUndoRecord(
            id: UUID(),
            createdAt: Date().addingTimeInterval(-60),
            itemID: "candidate",
            label: "com.example.agent",
            plistURL: fixture.plistURL,
            userID: getuid(),
            inverseOperation: .enable,
            previousState: Domain.StartupUndoStateSnapshot(state: .loadedEnabled)
        )
        try await undo.append(oldRecord)
        let manager = Domain.UserLaunchAgentManager(
            processRunner: RecordingRunner(responses: []),
            stateResolver: QueueStateResolver(states: [.disabled]),
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate(state: .loadedEnabled)
        let preview = try await manager.preview(candidate: candidate, operation: .disable)

        do {
            _ = try await manager.perform(preview, candidate: candidate)
            XCTFail("Expected changed state to fail before creating a recovery record")
        } catch let error as Domain.StartupManagementError {
            XCTAssertEqual(error, .startupStateChanged)
        }
        let recoveryRecordID = await manager.consumeRecoveryRecordID(for: preview.id)
        XCTAssertNil(recoveryRecordID)
        let records = try await undo.allRecords()
        XCTAssertEqual(records, [oldRecord])
    }

    func testPerformRejectsFreshSignatureIdentityChange() async throws {
        let fixture = try Fixture()
        let verifier = MutableStartupSignatureVerifier(inspection: FixedStartupSignatureVerifier.example.inspection)
        let runner = RecordingRunner(responses: [])
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: QueueStateResolver(states: [.loadedEnabled]),
            undoStore: MemoryUndoStore(),
            planBuilder: fixture.planBuilder,
            signatureVerifier: verifier
        )
        let candidate = fixture.candidate()
        let preview = try await manager.preview(candidate: candidate, operation: .disable)
        await verifier.setInspection(StartupSignatureInspection(
            isSigned: true,
            isValid: true,
            teamIdentifier: "REPLACEDTEAM",
            signingIdentifier: "com.example.replaced",
            designatedRequirement: "identifier com.example.replaced and anchor apple generic",
            status: 0
        ))

        do {
            _ = try await manager.perform(preview, candidate: candidate)
            XCTFail("Expected replaced signing identity to be rejected")
        } catch let error as Domain.StartupManagementError {
            XCTAssertEqual(error, .startupIdentityChanged)
        }
        let invocations = await runner.invocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testSuccessfulDisableRequiresObservedStateAndPersistsUndo() async throws {
        let fixture = try Fixture()
        let runner = RecordingRunner(responses: [.success, .success])
        let states = QueueStateResolver(states: [.loadedEnabled, .disabled])
        let undo = MemoryUndoStore()
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: states,
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate(state: .loadedEnabled)
        let preview = try await manager.preview(candidate: candidate, operation: .disable)
        let result = try await manager.perform(preview, candidate: candidate)

        XCTAssertEqual(result.verifiedState.enablement, .disabled)
        XCTAssertNotNil(result.undoRecordID)
        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.map(\.arguments), preview.commands.map(\.arguments))
        let records = try await undo.allRecords()
        XCTAssertEqual(records.count, 1)
        let recoveryRecordID = await manager.consumeRecoveryRecordID(for: preview.id)
        XCTAssertEqual(recoveryRecordID, records[0].id)
        XCTAssertEqual(records[0].inverseOperation, .enable)
    }

    func testFailureAfterPartialExecutionRetainsUndoRecordAndDoesNotReportSuccess() async throws {
        let fixture = try Fixture()
        let runner = RecordingRunner(responses: [.success, .failure(status: 5, output: "denied")])
        let states = QueueStateResolver(states: [.loadedEnabled])
        let undo = MemoryUndoStore()
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: states,
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate(state: .loadedEnabled)
        let preview = try await manager.preview(candidate: candidate, operation: .disable)

        do {
            _ = try await manager.perform(preview, candidate: candidate)
            XCTFail("Expected process failure")
        } catch let error as Domain.StartupManagementError {
            guard case let .processFailed(arguments, status, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(arguments.first, "disable")
            XCTAssertEqual(status, 5)
        }
        let records = try await undo.allRecords()
        XCTAssertEqual(records.count, 1)
        let recoveryRecordID = await manager.consumeRecoveryRecordID(for: preview.id)
        XCTAssertEqual(recoveryRecordID, records[0].id)
    }

    func testVerificationMismatchFailsAndRetainsUndoRecord() async throws {
        let fixture = try Fixture()
        let runner = RecordingRunner(responses: [.success, .success])
        let states = QueueStateResolver(states: [.loadedEnabled, .loadedEnabled])
        let undo = MemoryUndoStore()
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: states,
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate(state: .loadedEnabled)
        let preview = try await manager.preview(candidate: candidate, operation: .disable)

        do {
            _ = try await manager.perform(preview, candidate: candidate)
            XCTFail("Expected verification failure")
        } catch let error as Domain.StartupManagementError {
            guard case .verificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let records = try await undo.allRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testCancellationPropagatesAndRetainsRecoveryRecord() async throws {
        let fixture = try Fixture()
        let runner = RecordingRunner(responses: [.cancelled])
        let states = QueueStateResolver(states: [.loadedEnabled])
        let undo = MemoryUndoStore()
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: states,
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate(state: .loadedEnabled)
        let preview = try await manager.preview(candidate: candidate, operation: .disable)
        do {
            _ = try await manager.perform(preview, candidate: candidate)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let records = try await undo.allRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testUndoRestoreRevalidatesIdentityAndRemovesRecordOnlyAfterVerifiedSuccess() async throws {
        let fixture = try Fixture()
        let runner = RecordingRunner(responses: [.success, .success, .success, .success])
        let states = QueueStateResolver(states: [
            .loadedEnabled, .disabled,
            .disabled, .loadedEnabled
        ])
        let undo = MemoryUndoStore()
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: states,
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate(state: .loadedEnabled)
        let preview = try await manager.preview(candidate: candidate, operation: .disable)
        let disabled = try await manager.perform(preview, candidate: candidate)
        let recordID = try XCTUnwrap(disabled.undoRecordID)

        let mismatch = fixture.candidate(id: "different-id")
        do {
            _ = try await manager.restore(undoRecordID: recordID, candidate: mismatch)
            XCTFail("Expected record mismatch")
        } catch let error as Domain.StartupManagementError {
            XCTAssertEqual(error, .undoRecordMismatch)
        }
        let recordsBeforeRestore = try await undo.allRecords()
        XCTAssertEqual(recordsBeforeRestore.count, 1)

        let restored = try await manager.restore(undoRecordID: recordID, candidate: candidate)
        XCTAssertEqual(restored.verifiedState.enablement, .enabled)
        let recordsAfterRestore = try await undo.allRecords()
        XCTAssertTrue(recordsAfterRestore.isEmpty)
    }

    func testPersistedUndoIsReloadedReadOnlyOnlyForTheExactCurrentIdentity() async throws {
        let fixture = try Fixture()
        let undo = MemoryUndoStore()
        let initialManager = Domain.UserLaunchAgentManager(
            processRunner: RecordingRunner(responses: [.success, .success]),
            stateResolver: QueueStateResolver(states: [.loadedEnabled, .disabled]),
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let enabledCandidate = fixture.candidate(state: .loadedEnabled)
        let preview = try await initialManager.preview(candidate: enabledCandidate, operation: .disable)
        let disabled = try await initialManager.perform(preview, candidate: enabledCandidate)
        let recordID = try XCTUnwrap(disabled.undoRecordID)

        let restartedRunner = RecordingRunner(responses: [])
        let restartedManager = Domain.UserLaunchAgentManager(
            processRunner: restartedRunner,
            stateResolver: QueueStateResolver(states: []),
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let scannedCandidate = fixture.candidate(state: .disabled)
        let recovery = try await restartedManager.latestRecoverableUndo(candidates: [scannedCandidate])

        XCTAssertEqual(recovery?.recordID, recordID)
        XCTAssertEqual(recovery?.candidate.id, scannedCandidate.id)
        let restartedInvocations = await restartedRunner.invocations()
        XCTAssertTrue(restartedInvocations.isEmpty)
        let wrongCandidate = fixture.candidate(id: "replacement", state: .disabled)
        let wrongCandidateRecovery = try await restartedManager.latestRecoverableUndo(
            candidates: [wrongCandidate]
        )
        XCTAssertNil(wrongCandidateRecovery)

        let replacedIdentityManager = Domain.UserLaunchAgentManager(
            processRunner: RecordingRunner(responses: []),
            stateResolver: QueueStateResolver(states: []),
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier(inspection: StartupSignatureInspection(
                isSigned: true,
                isValid: true,
                teamIdentifier: "REPLACEDTEAM",
                signingIdentifier: "com.example.replaced",
                designatedRequirement: "identifier com.example.replaced and anchor apple generic",
                status: 0
            ))
        )
        let replacedIdentityRecovery = try await replacedIdentityManager.latestRecoverableUndo(
            candidates: [scannedCandidate]
        )
        let retainedRecordIDs = try await undo.allRecords().map(\.id)
        XCTAssertNil(replacedIdentityRecovery)
        XCTAssertEqual(retainedRecordIDs, [recordID])
    }

    func testUndoRestoresEnabledButNotLoadedWithoutBootstrappingTheAgent() async throws {
        let fixture = try Fixture()
        let runner = RecordingRunner(responses: [.success, .success])
        let states = QueueStateResolver(states: [
            .enabledNotLoaded, .disabled,
            .disabled, .enabledNotLoaded,
        ])
        let undo = MemoryUndoStore()
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: states,
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate(state: .enabledNotLoaded)
        let preview = try await manager.preview(candidate: candidate, operation: .disable)
        let disabled = try await manager.perform(preview, candidate: candidate)
        let recordID = try XCTUnwrap(disabled.undoRecordID)

        let restored = try await manager.restore(undoRecordID: recordID, candidate: candidate)
        XCTAssertEqual(restored.verifiedState, .enabledNotLoaded)
        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.map(\.arguments), [
            ["disable", "gui/\(getuid())/com.example.agent"],
            ["enable", "gui/\(getuid())/com.example.agent"],
        ])
        XCTAssertFalse(invocations.flatMap(\.arguments).contains("bootstrap"))
    }

    func testUndoRestoresDisabledButLoadedWithoutBootingOutTheAgent() async throws {
        let fixture = try Fixture()
        let runner = RecordingRunner(responses: [.success, .success])
        let states = QueueStateResolver(states: [
            .disabledLoaded, .loadedEnabled,
            .loadedEnabled, .disabledLoaded,
        ])
        let undo = MemoryUndoStore()
        let manager = Domain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: states,
            undoStore: undo,
            planBuilder: fixture.planBuilder,
            signatureVerifier: FixedStartupSignatureVerifier.example
        )
        let candidate = fixture.candidate(state: .disabledLoaded)
        let preview = try await manager.preview(candidate: candidate, operation: .enable)
        let enabled = try await manager.perform(preview, candidate: candidate)
        let recordID = try XCTUnwrap(enabled.undoRecordID)

        let restored = try await manager.restore(undoRecordID: recordID, candidate: candidate)
        XCTAssertEqual(restored.verifiedState, .disabledLoaded)
        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.map(\.arguments), [
            ["enable", "gui/\(getuid())/com.example.agent"],
            ["disable", "gui/\(getuid())/com.example.agent"],
        ])
        XCTAssertFalse(invocations.flatMap(\.arguments).contains("bootout"))
    }

    func testFileUndoStorePersistsAndRefusesCorruptData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartupUndoTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("undo.json")
        let store = Domain.FileStartupUndoStore(fileURL: file)
        let record = Domain.StartupUndoRecord(
            id: UUID(),
            createdAt: Date(),
            itemID: "item",
            label: "com.example.agent",
            plistURL: root.appendingPathComponent("agent.plist"),
            userID: getuid(),
            inverseOperation: .enable,
            previousState: Domain.StartupUndoStateSnapshot(state: .loadedEnabled)
        )
        try await store.append(record)
        let reopened = Domain.FileStartupUndoStore(fileURL: file)
        let reopenedRecord = try await reopened.record(id: record.id)
        XCTAssertEqual(reopenedRecord, record)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)

        let expired = Domain.StartupUndoRecord(
            id: UUID(),
            createdAt: Date().addingTimeInterval(-3 * 24 * 60 * 60),
            itemID: "expired",
            label: "com.example.expired",
            plistURL: root.appendingPathComponent("expired.plist"),
            userID: getuid(),
            inverseOperation: .disable,
            previousState: Domain.StartupUndoStateSnapshot(state: .disabled)
        )
        let expiring = Domain.FileStartupUndoStore(
            fileURL: root.appendingPathComponent("expiring.json"),
            retentionPeriod: 24 * 60 * 60
        )
        try await expiring.append(expired)
        let expiredRecords = try await expiring.allRecords()
        XCTAssertTrue(expiredRecords.isEmpty)

        let corruptFile = root.appendingPathComponent("corrupt.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptFile)
        let corrupt = Domain.FileStartupUndoStore(fileURL: corruptFile)
        do {
            _ = try await corrupt.allRecords()
            XCTFail("Expected persistence error")
        } catch let error as Domain.StartupManagementError {
            guard case .persistenceFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLaunchctlResolverDoesNotTreatMissingPIDAsDisabled() async throws {
        let runner = ArgumentRunner { arguments in
            if arguments.first == "print" {
                return Domain.StartupProcessResult(
                    standardOutput: "state = waiting\nlast exit code = 0",
                    standardError: "",
                    terminationStatus: 0
                )
            }
            return Domain.StartupProcessResult(
                standardOutput: "disabled services = { \"com.example.agent\" => enabled }",
                standardError: "",
                terminationStatus: 0
            )
        }
        let resolver = Domain.LaunchctlStartupStateResolver(runner: runner)
        let state = try await resolver.resolve(label: "com.example.agent", userID: getuid())
        XCTAssertEqual(state.enablement, .enabled)
        XCTAssertEqual(state.load, .onDemand)
        XCTAssertEqual(state.process, .waiting)
    }

    func testLaunchctlResolverParsesCurrentDisabledWordFormat() async throws {
        let runner = ArgumentRunner { arguments in
            if arguments.first == "print" {
                return Domain.StartupProcessResult(
                    standardOutput: "",
                    standardError: "Could not find service",
                    terminationStatus: 113
                )
            }
            return Domain.StartupProcessResult(
                standardOutput: "disabled services = { \"com.example.agent\" => disabled }",
                standardError: "",
                terminationStatus: 0
            )
        }
        let resolver = Domain.LaunchctlStartupStateResolver(runner: runner)
        let state = try await resolver.resolve(label: "com.example.agent", userID: getuid())
        XCTAssertEqual(state.enablement, .disabled)
        XCTAssertEqual(state.load, .notLoaded)
        XCTAssertEqual(state.process, .stopped)
    }

    func testLaunchctlResolverFailsClosedOnPermissionError() async throws {
        let runner = ArgumentRunner { arguments in
            if arguments.first == "print" {
                return Domain.StartupProcessResult(
                    standardOutput: "",
                    standardError: "Not privileged",
                    terminationStatus: 1
                )
            }
            return Domain.StartupProcessResult(
                standardOutput: "disabled services = { \"com.example.agent\" => true }",
                standardError: "",
                terminationStatus: 0
            )
        }
        let resolver = Domain.LaunchctlStartupStateResolver(runner: runner)
        do {
            _ = try await resolver.resolve(label: "com.example.agent", userID: getuid())
            XCTFail("Expected state lookup to fail closed")
        } catch let error as Domain.StartupManagementError {
            guard case .stateUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDefaultRunnerHonorsTimeoutWithoutTouchingLaunchd() async throws {
        let cleanupQueue = DispatchQueue(label: "StartupItemManagementTests.CleanupReaper")
        let cleanupReaper = ShellProcessCleanupReaper(
            retryDelay: 0.01,
            maximumRetryCount: 6
        ) { delay, operation in
            cleanupQueue.asyncAfter(deadline: .now() + delay) {
                operation.run()
            }
        }
        let runner = Domain.CancellableStartupProcessRunner(cleanupReaper: cleanupReaper)
        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["1"],
                timeout: 0.05
            )
            XCTFail("Expected timeout")
        } catch let error as ShellError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected shell error: \(error)")
            }
        }
    }
}

private extension StartupItemManagementTests {
    final class Fixture {
        let root: URL
        let plistURL: URL
        let configuration: Domain.LaunchdConfiguration
        let resolver: Domain.StartupCapabilityResolver
        let planBuilder: Domain.StartupOperationPlanBuilder

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("StartupManagement-\(UUID().uuidString)", isDirectory: true)
            let directory = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            plistURL = directory.appendingPathComponent("com.example.agent.plist")
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "Label": "com.example.agent",
                    "Program": "/usr/bin/true",
                ],
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
            configuration = try LaunchdPlistParser().parse(data: data, plistURL: plistURL)
            resolver = Domain.StartupCapabilityResolver(
                platform: .nonSandboxDirect,
                currentUserID: getuid(),
                homeDirectory: root
            )
            planBuilder = Domain.StartupOperationPlanBuilder(capabilityResolver: resolver)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func candidate(
            id: String = "candidate",
            state: Domain.State = .loadedEnabled
        ) -> Domain.Candidate {
            Domain.Candidate(
                id: id,
                source: .launchdPlist,
                kind: .userLaunchAgent,
                scope: .currentUser,
                name: "Example Agent",
                label: "com.example.agent",
                plistURL: plistURL,
                executableURL: configuration.resolvedExecutableURL,
                applicationURL: nil,
                configuration: configuration,
                state: state,
                attribution: Domain.Attribution(
                    applicationBundleIdentifier: "com.example.app",
                    applicationURL: root.appendingPathComponent("Example.app"),
                    applicationName: "Example",
                    developerName: "Example Developer",
                    teamIdentifier: "EXAMPLETEAM",
                    designatedRequirement: nil,
                    evidence: [Domain.AttributionEvidence(
                        kind: .embeddedInApplication,
                        value: root.appendingPathComponent("Example.app").path,
                        confidence: .verified
                    )]
                ),
                actionCapability: .readOnly,
                diagnosticEvidence: ["valid-code-signature"]
            )
        }
    }
}

private extension StartupItemsDomain.State {
    static let loadedEnabled = StartupItemsDomain.State(
        registration: .registered,
        authorization: .notApplicable,
        enablement: .enabled,
        load: .loaded,
        process: .running(pid: 123),
        management: .directlyManageable
    )

    static let disabled = StartupItemsDomain.State(
        registration: .discoveredFromFile,
        authorization: .notApplicable,
        enablement: .disabled,
        load: .notLoaded,
        process: .stopped,
        management: .directlyManageable
    )

    static let enabledNotLoaded = StartupItemsDomain.State(
        registration: .discoveredFromFile,
        authorization: .notApplicable,
        enablement: .enabled,
        load: .notLoaded,
        process: .stopped,
        management: .directlyManageable
    )

    static let disabledLoaded = StartupItemsDomain.State(
        registration: .registered,
        authorization: .notApplicable,
        enablement: .disabled,
        load: .loaded,
        process: .running(pid: 123),
        management: .directlyManageable
    )
}

private actor RecordingRunner: StartupItemsDomain.StartupProcessRunning {
    enum Response: Sendable {
        case success
        case failure(status: Int32, output: String)
        case cancelled
    }

    struct Invocation: Sendable {
        let executableURL: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    private var responses: [Response]
    private var recorded: [Invocation] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> StartupItemsDomain.StartupProcessResult {
        recorded.append(Invocation(executableURL: executableURL, arguments: arguments, timeout: timeout))
        guard !responses.isEmpty else {
            return StartupItemsDomain.StartupProcessResult(
                standardOutput: "",
                standardError: "",
                terminationStatus: 0
            )
        }
        switch responses.removeFirst() {
        case .success:
            return StartupItemsDomain.StartupProcessResult(
                standardOutput: "",
                standardError: "",
                terminationStatus: 0
            )
        case let .failure(status, output):
            return StartupItemsDomain.StartupProcessResult(
                standardOutput: "",
                standardError: output,
                terminationStatus: status
            )
        case .cancelled:
            throw CancellationError()
        }
    }

    func invocations() -> [Invocation] {
        recorded
    }
}

private actor QueueStateResolver: StartupItemsDomain.StartupManagedStateResolving {
    private var states: [StartupItemsDomain.State]

    init(states: [StartupItemsDomain.State]) {
        self.states = states
    }

    func resolve(label: String, userID: uid_t) async throws -> StartupItemsDomain.State {
        guard !states.isEmpty else {
            throw StartupItemsDomain.StartupManagementError.stateUnavailable("fixture-exhausted")
        }
        return states.removeFirst()
    }
}

private actor MemoryUndoStore: StartupItemsDomain.StartupUndoStoring {
    private var records: [StartupItemsDomain.StartupUndoRecord] = []

    func append(_ record: StartupItemsDomain.StartupUndoRecord) async throws {
        records.append(record)
    }

    func record(id: UUID) async throws -> StartupItemsDomain.StartupUndoRecord? {
        records.first { $0.id == id }
    }

    func allRecords() async throws -> [StartupItemsDomain.StartupUndoRecord] {
        records
    }

    func remove(id: UUID) async throws {
        records.removeAll { $0.id == id }
    }
}

private struct ArgumentRunner: StartupItemsDomain.StartupProcessRunning {
    let response: @Sendable ([String]) -> StartupItemsDomain.StartupProcessResult

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> StartupItemsDomain.StartupProcessResult {
        response(arguments)
    }
}

private struct FixedStartupSignatureVerifier: StartupSignatureInspecting {
    static let example = FixedStartupSignatureVerifier(
        inspection: StartupSignatureInspection(
            isSigned: true,
            isValid: true,
            teamIdentifier: "EXAMPLETEAM",
            signingIdentifier: "com.example.agent",
            designatedRequirement: "identifier com.example.agent and anchor apple generic",
            status: 0
        )
    )

    let inspection: StartupSignatureInspection

    func inspectFresh(_ URL: URL) async -> StartupSignatureInspection {
        inspection
    }
}

private actor MutableStartupSignatureVerifier: StartupSignatureInspecting {
    private var inspection: StartupSignatureInspection

    init(inspection: StartupSignatureInspection) {
        self.inspection = inspection
    }

    func setInspection(_ inspection: StartupSignatureInspection) {
        self.inspection = inspection
    }

    func inspectFresh(_ URL: URL) async -> StartupSignatureInspection {
        inspection
    }
}
