import CryptoKit
import Foundation

extension StartupItemsDomain {
    struct StartupOperationPlanBuilder: Sendable {
        private struct ValidatedPlist {
            let contentDigest: String
            let resolvedExecutableURL: URL
        }

        private let capabilityResolver: StartupCapabilityResolver
        private let launchctlURL = URL(fileURLWithPath: "/bin/launchctl")
        private let commandTimeout: TimeInterval

        init(
            capabilityResolver: StartupCapabilityResolver,
            commandTimeout: TimeInterval = 8
        ) {
            self.capabilityResolver = capabilityResolver
            self.commandTimeout = commandTimeout
        }

        func plan(
            for candidate: Candidate,
            operation: StartupOperationKind,
            observedState: State? = nil,
            restoreShouldBeLoaded: Bool? = nil
        ) throws -> StartupOperationPlan {
            let destination = capabilityResolver.destination(for: candidate)
            let requiresAdministrator = destination == .administratorHelperUnavailable
            guard destination == .directlyManageable || requiresAdministrator else {
                throw StartupManagementError.unsupported(
                    String(describing: destination)
                )
            }
            let capability = capabilityResolver.capability(for: candidate)
            let operationIsAllowed = switch operation {
            case .enable: capability.canEnableDirectly
            case .disable: capability.canDisableDirectly
            case .stopCurrentSession: capability.canStopCurrentSession
            }
            guard operationIsAllowed else {
                throw StartupManagementError.unsupported(
                    "operation-not-allowed: \(operation.rawValue)"
                )
            }
            guard let label = candidate.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Self.isValidLabel(label) else {
                throw StartupManagementError.invalidLabel
            }
            guard let plistURL = candidate.plistURL else {
                throw StartupManagementError.invalidPlistPath
            }
            let domain: String
            let expectedOwnerID: uid_t
            let expectedDirectory: URL
            if requiresAdministrator {
                guard operation != .stopCurrentSession,
                      let administrativeDomain = capabilityResolver.administrativeDomain(for: plistURL) else {
                    throw StartupManagementError.invalidPlistPath
                }
                domain = administrativeDomain
                expectedOwnerID = 0
                expectedDirectory = plistURL.standardizedFileURL.deletingLastPathComponent()
            } else {
                guard capabilityResolver.isDirectUserLaunchAgentPath(plistURL) else {
                    throw StartupManagementError.invalidPlistPath
                }
                domain = "gui/\(capabilityResolver.currentUserID)"
                expectedOwnerID = capabilityResolver.currentUserID
                expectedDirectory = capabilityResolver.userLaunchAgentsDirectory
            }
            let validatedPlist = try validatePlist(
                plistURL,
                expectedOwnerID: expectedOwnerID,
                expectedDirectory: expectedDirectory,
                expectedLabel: label,
                expectedConfiguration: candidate.configuration,
                expectedExecutableURL: candidate.executableURL,
                applicationBundleURL: candidate.attribution?.applicationURL ?? candidate.applicationURL
            )

            let state = observedState ?? candidate.state
            let userID = capabilityResolver.currentUserID
            let serviceTarget = "\(domain)/\(label)"
            let commands: [StartupOperationCommand]
            let impact: String
            let warnings: [String]

            switch operation {
            case .disable:
                var result = [StartupOperationCommand]()
                // A recovery may need to restore the valid launchd state
                // "disabled, but still loaded for this session". In that
                // case persist the disabled override without booting the
                // service out of the domain.
                if restoreShouldBeLoaded != true, Self.isLoadedOrRunning(state) {
                    result.append(command(["bootout", serviceTarget]))
                }
                result.append(command(["disable", serviceTarget]))
                commands = result
                impact = L10n.text(
                    "停止此用户代理，并阻止它以后再次载入。",
                    "Stops this user LaunchAgent and prevents it from loading again."
                )
                warnings = [L10n.text(
                    "所属应用可能会重新注册此启动项。",
                    "The parent application may register the LaunchAgent again."
                )]
            case .enable:
                var result = [command(["enable", serviceTarget])]
                let shouldBootstrap = restoreShouldBeLoaded ?? !Self.isLoaded(state)
                if shouldBootstrap, !Self.isLoaded(state) {
                    result.append(command(["bootstrap", domain, plistURL.path]))
                }
                commands = result
                impact = L10n.text(
                    "允许此用户代理载入并恢复注册。",
                    "Allows this user LaunchAgent to load and restores its registration."
                )
                warnings = candidate.hasAuthoritativeParentApplication
                    ? []
                    : [L10n.text(
                        "已验证配置文件与可执行文件签名，但所属应用尚未可靠识别；启用后可能立即运行该程序。",
                        "The configuration and executable signature are verified, but the parent app is not reliably identified; enabling may run this program immediately."
                    )]
            case .stopCurrentSession:
                commands = Self.isLoadedOrRunning(state)
                    ? [command(["bootout", serviceTarget])]
                    : []
                impact = L10n.text(
                    "仅停止当前实例，不会永久停用此用户代理。",
                    "Stops the current instance without persistently disabling the LaunchAgent."
                )
                warnings = [L10n.text(
                    "launchd 或所属应用可能会再次启动它。",
                    "launchd or the parent application may start it again."
                )]
            }

            return StartupOperationPlan(
                itemID: candidate.id,
                kind: operation,
                label: label,
                plistURL: plistURL.standardizedFileURL,
                userID: userID,
                domain: domain,
                requiresAdministrator: requiresAdministrator,
                plistContentDigest: validatedPlist.contentDigest,
                resolvedExecutableURL: validatedPlist.resolvedExecutableURL,
                observedState: state,
                commands: commands,
                impactSummary: impact,
                warnings: warnings
            )
        }

        private func command(_ arguments: [String]) -> StartupOperationCommand {
            StartupOperationCommand(
                executableURL: launchctlURL,
                arguments: arguments,
                timeout: commandTimeout
            )
        }

        private func validatePlist(
            _ url: URL,
            expectedOwnerID: uid_t,
            expectedDirectory: URL,
            expectedLabel: String,
            expectedConfiguration: LaunchdConfiguration?,
            expectedExecutableURL: URL?,
            applicationBundleURL: URL?
        ) throws -> ValidatedPlist {
            let normalized = url.standardizedFileURL
            let resolved = normalized.resolvingSymlinksInPath()
            let expectedParent = expectedDirectory.resolvingSymlinksInPath()
            guard resolved.deletingLastPathComponent() == expectedParent,
                  resolved == normalized else {
                throw StartupManagementError.invalidPlistPath
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: normalized.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let owner = attributes[.ownerAccountID] as? NSNumber,
                      owner.uint32Value == expectedOwnerID,
                      let permissions = attributes[.posixPermissions] as? NSNumber,
                      permissions.uint16Value & 0o022 == 0 else {
                    throw StartupManagementError.unsafePlistPermissions
                }
                let data = try Data(contentsOf: normalized, options: [.mappedIfSafe])
                let currentConfiguration = try LaunchdPlistParser().parse(
                    data: data,
                    plistURL: normalized,
                    applicationBundleURL: applicationBundleURL
                )
                guard currentConfiguration.label == expectedLabel else {
                    throw StartupManagementError.invalidLabel
                }
                guard let expectedConfiguration,
                      Self.sameLaunchIdentity(currentConfiguration, expectedConfiguration),
                      let currentExecutableURL = currentConfiguration.resolvedExecutableURL?.standardizedFileURL,
                      let expectedExecutableURL = expectedExecutableURL?.standardizedFileURL,
                      currentExecutableURL == expectedExecutableURL else {
                    throw StartupManagementError.startupConfigurationChanged
                }
                return ValidatedPlist(
                    contentDigest: Self.sha256(data),
                    resolvedExecutableURL: currentExecutableURL
                )
            } catch let error as StartupManagementError {
                throw error
            } catch is LaunchdPlistParserError {
                throw StartupManagementError.invalidLabel
            } catch {
                throw StartupManagementError.invalidPlistPath
            }
        }

        private static func sameLaunchIdentity(
            _ lhs: LaunchdConfiguration,
            _ rhs: LaunchdConfiguration
        ) -> Bool {
            lhs.program == rhs.program
                && lhs.programArguments == rhs.programArguments
                && lhs.bundleProgram == rhs.bundleProgram
                && lhs.resolvedExecutableURL?.standardizedFileURL
                    == rhs.resolvedExecutableURL?.standardizedFileURL
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func isValidLabel(_ label: String) -> Bool {
            !label.isEmpty
                && label.utf8.count <= 255
                && !label.contains("/")
                && label.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
        }

        private static func isLoaded(_ state: State) -> Bool {
            state.load == .loaded || state.load == .onDemand
        }

        private static func isLoadedOrRunning(_ state: State) -> Bool {
            if isLoaded(state) { return true }
            switch state.process {
            case .running, .waiting:
                return true
            case .stopped, .failed, .unknown:
                return false
            }
        }
    }

    actor UserLaunchAgentManager {
        private let processRunner: any StartupProcessRunning
        private let stateResolver: any StartupManagedStateResolving
        private let undoStore: any StartupUndoStoring
        private var planBuilder: StartupOperationPlanBuilder?
        private let liveHomeDirectory: URL?
        private let signatureVerifier: any StartupSignatureInspecting
        private let pathValidator: StartupPathValidator
        private var recoveryRecordIDsByOperationID: [UUID: UUID] = [:]

        init(
            processRunner: any StartupProcessRunning,
            stateResolver: any StartupManagedStateResolving,
            undoStore: any StartupUndoStoring,
            planBuilder: StartupOperationPlanBuilder,
            signatureVerifier: any StartupSignatureInspecting = StartupCodeSignatureVerifier(),
            pathValidator: StartupPathValidator = StartupPathValidator()
        ) {
            self.processRunner = processRunner
            self.stateResolver = stateResolver
            self.undoStore = undoStore
            self.planBuilder = planBuilder
            liveHomeDirectory = nil
            self.signatureVerifier = signatureVerifier
            self.pathValidator = pathValidator
        }

        private init(
            processRunner: any StartupProcessRunning,
            stateResolver: any StartupManagedStateResolving,
            undoStore: any StartupUndoStoring,
            liveHomeDirectory: URL,
            signatureVerifier: any StartupSignatureInspecting = StartupCodeSignatureVerifier(),
            pathValidator: StartupPathValidator = StartupPathValidator()
        ) {
            self.processRunner = processRunner
            self.stateResolver = stateResolver
            self.undoStore = undoStore
            planBuilder = nil
            self.liveHomeDirectory = liveHomeDirectory
            self.signatureVerifier = signatureVerifier
            self.pathValidator = pathValidator
        }

        /// Constructs the direct-distribution manager without scanning or
        /// mutating launchd. Commands are only issued after a caller requests
        /// an operation and confirms its generated preview.
        static func live(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> UserLaunchAgentManager {
            let runner = CancellableStartupProcessRunner()
            return UserLaunchAgentManager(
                processRunner: runner,
                stateResolver: LaunchctlStartupStateResolver(runner: runner),
                undoStore: FileStartupUndoStore.defaultStore(),
                liveHomeDirectory: homeDirectory
            )
        }

        private var resolvedPlanBuilder: StartupOperationPlanBuilder {
            if let planBuilder { return planBuilder }
            let builder = StartupOperationPlanBuilder(
                capabilityResolver: StartupCapabilityResolver(
                    platform: .currentApplication(),
                    currentUserID: getuid(),
                    homeDirectory: liveHomeDirectory
                        ?? FileManager.default.homeDirectoryForCurrentUser
                )
            )
            planBuilder = builder
            return builder
        }

        func preview(
            candidate: Candidate,
            operation: StartupOperationKind
        ) async throws -> StartupOperationPlan {
            let first = try resolvedPlanBuilder.plan(for: candidate, operation: operation)
            let binding = try await identityBinding(for: first, candidate: candidate)
            // Re-read after code-signature validation so the returned preview
            // binds one coherent plist digest, executable path and identity.
            let second = try resolvedPlanBuilder.plan(for: candidate, operation: operation)
            guard first.plistContentDigest == second.plistContentDigest,
                  first.resolvedExecutableURL == second.resolvedExecutableURL else {
                throw StartupManagementError.startupConfigurationChanged
            }
            return second.bindingIdentity(binding)
        }

        func perform(
            _ preview: StartupOperationPlan,
            candidate: Candidate
        ) async throws -> StartupOperationResult {
            guard preview.itemID == candidate.id,
                  preview.label == candidate.label,
                  preview.plistURL == candidate.plistURL?.standardizedFileURL else {
                throw StartupManagementError.undoRecordMismatch
            }
            return try await execute(
                candidate: candidate,
                operation: preview.kind,
                shouldCreateUndo: preview.kind != .stopCurrentSession,
                confirmedPreview: preview,
                operationID: preview.id,
                restoringState: nil
            )
        }

        func consumeRecoveryRecordID(for operationID: UUID) -> UUID? {
            recoveryRecordIDsByOperationID.removeValue(forKey: operationID)
        }

        func restore(
            undoRecordID: UUID,
            candidate: Candidate
        ) async throws -> StartupOperationResult {
            guard let record = try await undoStore.record(id: undoRecordID) else {
                throw StartupManagementError.undoRecordNotFound
            }
            guard record.itemID == candidate.id,
                  record.label == candidate.label,
                  record.plistURL == candidate.plistURL?.standardizedFileURL,
                  record.userID == getuid() else {
                throw StartupManagementError.undoRecordMismatch
            }
            guard let plistContentDigest = record.plistContentDigest,
                  let identityBinding = record.identityBinding else {
                throw StartupManagementError.startupIdentityChanged
            }
            let result = try await execute(
                candidate: candidate,
                operation: record.inverseOperation,
                shouldCreateUndo: false,
                confirmedPreview: nil,
                operationID: nil,
                restoringState: record.previousState,
                restoringPlistContentDigest: plistContentDigest,
                restoringIdentityBinding: identityBinding
            )
            try await undoStore.remove(id: record.id)
            return result
        }

        func latestRecoverableUndo(
            candidates: [Candidate],
            now: Date = Date()
        ) async throws -> (recordID: UUID, candidate: Candidate)? {
            let cutoff = now.addingTimeInterval(-StartupUndoRecord.defaultRetentionPeriod)
            let records = try await undoStore.allRecords()
                .filter { $0.createdAt >= cutoff }
                .sorted { $0.createdAt > $1.createdAt }

            for record in records {
                try Task.checkCancellation()
                guard let candidate = candidates.first(where: { Self.matches(record, candidate: $0) }),
                      let plistContentDigest = record.plistContentDigest,
                      let identityBinding = record.identityBinding else { continue }
                do {
                    let plan = try resolvedPlanBuilder.plan(
                        for: candidate,
                        operation: record.inverseOperation,
                        observedState: candidate.state,
                        restoreShouldBeLoaded: record.previousState.shouldBeLoaded
                    )
                    guard plan.plistContentDigest == plistContentDigest else { continue }
                    try await verifyIdentityBinding(identityBinding, plan: plan, candidate: candidate)
                    return (record.id, candidate)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            return nil
        }

        private func execute(
            candidate: Candidate,
            operation: StartupOperationKind,
            shouldCreateUndo: Bool,
            confirmedPreview: StartupOperationPlan?,
            operationID: UUID?,
            restoringState: StartupUndoStateSnapshot?,
            restoringPlistContentDigest: String? = nil,
            restoringIdentityBinding: StartupOperationIdentityBinding? = nil
        ) async throws -> StartupOperationResult {
            try Task.checkCancellation()
            // Validate attribution, label, ownership and the exact user
            // LaunchAgents path before consulting or mutating launchd.
            let validated = try resolvedPlanBuilder.plan(
                for: candidate,
                operation: operation,
                observedState: candidate.state
            )
            let label = validated.label
            let before: State
            do {
                before = try await stateResolver.resolve(label: label, userID: getuid())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw StartupManagementError.stateUnavailable(String(describing: error))
            }
            let unboundPlan = try resolvedPlanBuilder.plan(
                for: candidate,
                operation: operation,
                observedState: before,
                restoreShouldBeLoaded: restoringState?.shouldBeLoaded
            )

            if let restoringPlistContentDigest,
               restoringPlistContentDigest != unboundPlan.plistContentDigest {
                throw StartupManagementError.startupConfigurationChanged
            }

            if let confirmedPreview {
                guard confirmedPreview.plistContentDigest == unboundPlan.plistContentDigest,
                      confirmedPreview.resolvedExecutableURL == unboundPlan.resolvedExecutableURL else {
                    throw StartupManagementError.startupConfigurationChanged
                }
                guard Self.sameConfirmedState(confirmedPreview.observedState, before, operation: operation),
                      confirmedPreview.commands == unboundPlan.commands else {
                    throw StartupManagementError.startupStateChanged
                }
            }

            let binding: StartupOperationIdentityBinding
            if let restoringIdentityBinding {
                try await verifyIdentityBinding(
                    restoringIdentityBinding,
                    plan: unboundPlan,
                    candidate: candidate
                )
                binding = restoringIdentityBinding
            } else if let confirmedPreview,
               let confirmedBinding = confirmedPreview.identityBinding {
                try await verifyIdentityBinding(
                    confirmedBinding,
                    plan: unboundPlan,
                    candidate: candidate
                )
                binding = confirmedBinding
            } else {
                binding = try await identityBinding(for: unboundPlan, candidate: candidate)
            }
            let plan = unboundPlan.bindingIdentity(binding)

            let undoRecord: StartupUndoRecord?
            if shouldCreateUndo {
                let inverse = try Self.inverseOperation(for: operation, before: before)
                let record = StartupUndoRecord(
                    id: UUID(),
                    createdAt: Date(),
                    itemID: candidate.id,
                    label: plan.label,
                    plistURL: plan.plistURL,
                    userID: plan.userID,
                    inverseOperation: inverse,
                    previousState: StartupUndoStateSnapshot(state: before),
                    plistContentDigest: plan.plistContentDigest,
                    identityBinding: binding
                )
                try await undoStore.append(record)
                if let operationID {
                    recoveryRecordIDsByOperationID[operationID] = record.id
                }
                undoRecord = record
            } else {
                undoRecord = nil
            }

            do {
                for command in plan.commands {
                    try Task.checkCancellation()
                    // Revalidate immediately before every launchctl boundary.
                    // In particular, this prevents a same-label plist swap
                    // between the confirmation sheet and `bootstrap`.
                    let currentPlan = try resolvedPlanBuilder.plan(
                        for: candidate,
                        operation: operation,
                        observedState: before,
                        restoreShouldBeLoaded: restoringState?.shouldBeLoaded
                    )
                    guard currentPlan.plistContentDigest == plan.plistContentDigest,
                          currentPlan.resolvedExecutableURL == plan.resolvedExecutableURL else {
                        throw StartupManagementError.startupConfigurationChanged
                    }
                    try await verifyIdentityBinding(binding, plan: currentPlan, candidate: candidate)
                    let result = try await processRunner.run(
                        executableURL: command.executableURL,
                        arguments: command.arguments,
                        timeout: command.timeout
                    )
                    guard result.terminationStatus == 0 else {
                        throw StartupManagementError.processFailed(
                            arguments: command.arguments,
                            status: result.terminationStatus,
                            output: result.combinedOutput
                        )
                    }
                }
                try Task.checkCancellation()
                let observed = try await stateResolver.resolve(label: plan.label, userID: plan.userID)
                let didReachExpectedState = restoringState.map {
                    Self.didRestore($0, state: observed)
                } ?? Self.didReach(operation, state: observed)
                guard didReachExpectedState else {
                    throw StartupManagementError.verificationFailed(expected: operation, observed: observed)
                }
                return StartupOperationResult(
                    plan: plan,
                    verifiedState: observed,
                    undoRecordID: undoRecord?.id
                )
            } catch {
                // Keep the pre-written undo record whenever execution starts.
                // A launchctl command may have changed state before returning
                // an error or cancellation; removing the record here could
                // leave a partially applied operation without recovery.
                throw error
            }
        }

        private func identityBinding(
            for plan: StartupOperationPlan,
            candidate: Candidate
        ) async throws -> StartupOperationIdentityBinding {
            let executableURL = plan.resolvedExecutableURL.standardizedFileURL
            let path = pathValidator.inspect(executableURL)
            guard path.exists,
                  path.isExecutable,
                  path.symbolicLinkResolves,
                  !path.isGroupWritable,
                  !path.isWorldWritable,
                  !path.isInTemporaryDirectory,
                  !path.isInTrash else {
                throw StartupManagementError.startupIdentityChanged
            }
            let executableInspection = await signatureVerifier.inspectFresh(executableURL)
            guard executableInspection.isSigned, executableInspection.isValid else {
                throw StartupManagementError.startupIdentityChanged
            }

            let parentURL = candidate.hasAuthoritativeParentApplication
                ? (candidate.attribution?.applicationURL ?? candidate.applicationURL)?.standardizedFileURL
                : nil
            let parentInspection: StartupSignatureInspection?
            if let parentURL, parentURL != executableURL {
                let inspection = await signatureVerifier.inspectFresh(parentURL)
                guard inspection.isSigned, inspection.isValid else {
                    throw StartupManagementError.startupIdentityChanged
                }
                parentInspection = inspection
                if let parentTeam = inspection.teamIdentifier {
                    guard executableInspection.teamIdentifier == parentTeam else {
                        throw StartupManagementError.startupIdentityChanged
                    }
                }
            } else {
                parentInspection = nil
            }

            if let expectedTeam = candidate.attribution?.teamIdentifier {
                let observedTeam = parentInspection?.teamIdentifier ?? executableInspection.teamIdentifier
                guard expectedTeam == observedTeam else {
                    throw StartupManagementError.startupIdentityChanged
                }
            }

            return StartupOperationIdentityBinding(
                executableURL: executableURL,
                executableIdentity: StartupExecutableIdentity(executableInspection),
                parentApplicationURL: parentURL,
                parentApplicationIdentity: parentInspection.map(StartupExecutableIdentity.init)
            )
        }

        private func verifyIdentityBinding(
            _ expected: StartupOperationIdentityBinding,
            plan: StartupOperationPlan,
            candidate: Candidate
        ) async throws {
            guard expected.executableURL == plan.resolvedExecutableURL.standardizedFileURL else {
                throw StartupManagementError.startupIdentityChanged
            }
            let current = try await identityBinding(for: plan, candidate: candidate)
            guard current == expected else {
                throw StartupManagementError.startupIdentityChanged
            }
        }

        private static func matches(
            _ record: StartupUndoRecord,
            candidate: Candidate
        ) -> Bool {
            record.userID == getuid()
                && record.itemID == candidate.id
                && record.label == candidate.label
                && record.plistURL.standardizedFileURL == candidate.plistURL?.standardizedFileURL
        }

        private static func sameConfirmedState(
            _ preview: State,
            _ current: State,
            operation: StartupOperationKind
        ) -> Bool {
            guard preview.enablement == current.enablement else { return false }
            switch operation {
            case .disable:
                return current.enablement == .enabled
                    && isLoadedOrRunning(preview) == isLoadedOrRunning(current)
            case .enable:
                return current.enablement == .disabled
                    && isLoaded(preview) == isLoaded(current)
            case .stopCurrentSession:
                return isLoadedOrRunning(preview) && isLoadedOrRunning(current)
            }
        }

        private static func inverseOperation(
            for operation: StartupOperationKind,
            before: State
        ) throws -> StartupOperationKind {
            switch operation {
            case .disable where before.enablement == .enabled:
                return .enable
            case .enable where before.enablement == .disabled:
                return .disable
            default:
                throw StartupManagementError.startupStateChanged
            }
        }

        private static func isLoaded(_ state: State) -> Bool {
            state.load == .loaded || state.load == .onDemand
        }

        private static func isLoadedOrRunning(_ state: State) -> Bool {
            if isLoaded(state) { return true }
            switch state.process {
            case .running, .waiting:
                return true
            case .stopped, .failed, .unknown:
                return false
            }
        }

        private static func didReach(_ operation: StartupOperationKind, state: State) -> Bool {
            switch operation {
            case .disable:
                guard state.enablement == .disabled,
                      state.load == .notLoaded else { return false }
                return !state.process.isRunning
            case .enable:
                return state.enablement == .enabled
                    && (state.load == .loaded || state.load == .onDemand)
            case .stopCurrentSession:
                return state.load == .notLoaded && !state.process.isRunning
            }
        }

        private static func didRestore(
            _ snapshot: StartupUndoStateSnapshot,
            state: State
        ) -> Bool {
            guard state.enablement == snapshot.enablement else { return false }
            if snapshot.shouldBeLoaded {
                return isLoaded(state)
            }
            return state.load == .notLoaded && !state.process.isRunning
        }
    }
}

private extension StartupItemsDomain.ProcessState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
