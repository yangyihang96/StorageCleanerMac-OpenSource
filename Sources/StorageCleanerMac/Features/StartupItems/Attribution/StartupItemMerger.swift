import Foundation

struct StartupItemDeduplicator: Sendable {
    private struct MergeFingerprint: Sendable {
        let isOrphaned: Bool
        let id: String
        let label: String?
        let plistPath: String?
        let executablePath: String?
        let reliableApplicationIdentity: String?

        init(_ candidate: StartupItemsDomain.Candidate) {
            isOrphaned = candidate.kind == .orphanedItem
            id = candidate.id
            label = candidate.label
            plistPath = candidate.plistURL?.standardizedFileURL.path
            executablePath = candidate.executableURL?.standardizedFileURL.path
            reliableApplicationIdentity = candidate.reliableApplicationIdentity
        }
    }

    func deduplicate(_ candidates: [StartupItemsDomain.Candidate]) -> [StartupItemsDomain.Candidate] {
        var uniqueByID = [String: StartupItemsDomain.Candidate]()
        for candidate in candidates {
            if var existing = uniqueByID[candidate.id] {
                existing.diagnosticEvidence = Array(Set(existing.diagnosticEvidence + candidate.diagnosticEvidence)).sorted()
                existing.state = Self.mergedState(existing.state, candidate.state)
                uniqueByID[candidate.id] = existing
            } else {
                uniqueByID[candidate.id] = candidate
            }
        }

        var base = uniqueByID.values.filter { $0.source != .launchdRuntime }
        let runtime = uniqueByID.values.filter { $0.source == .launchdRuntime }
        for runtimeCandidate in runtime {
            let matching = base.indices.filter { index in
                guard base[index].scope == runtimeCandidate.scope,
                      base[index].label == runtimeCandidate.label else { return false }
                return runtimeCandidate.label != nil
            }
            if matching.isEmpty {
                base.append(runtimeCandidate)
            } else {
                for index in matching {
                    base[index].state = Self.mergedState(base[index].state, runtimeCandidate.state)
                    base[index].diagnosticEvidence = Array(
                        Set(base[index].diagnosticEvidence + runtimeCandidate.diagnosticEvidence)
                    ).sorted()
                }
            }
        }
        var linked = [StartupItemsDomain.Candidate]()
        var linkedFingerprints = [MergeFingerprint]()
        for candidate in base.sorted(by: { Self.sourcePriority($0.source) < Self.sourcePriority($1.source) }) {
            let fingerprint = MergeFingerprint(candidate)
            if let index = linkedFingerprints.firstIndex(where: {
                Self.shouldMerge($0, fingerprint)
            }) {
                linked[index].state = Self.mergedState(linked[index].state, candidate.state)
                linked[index].diagnosticEvidence = Array(
                    Set(linked[index].diagnosticEvidence + candidate.diagnosticEvidence)
                ).sorted()
                if (linked[index].attribution?.confidence ?? .unknown) < (candidate.attribution?.confidence ?? .unknown) {
                    linked[index].attribution = candidate.attribution
                    linked[index].applicationURL = candidate.applicationURL
                    linkedFingerprints[index] = MergeFingerprint(linked[index])
                }
            } else {
                linked.append(candidate)
                linkedFingerprints.append(fingerprint)
            }
        }
        let duplicateKeys = Set(
            Dictionary(grouping: linked.filter { $0.label != nil }, by: {
                "\($0.scope.rawValue):\($0.label ?? "")"
            })
            .filter { _, candidates in
                Set(candidates.compactMap { $0.plistURL?.standardizedFileURL.path }).count > 1
            }
            .keys
        )
        for index in linked.indices {
            let key = "\(linked[index].scope.rawValue):\(linked[index].label ?? "")"
            if duplicateKeys.contains(key), let label = linked[index].label {
                linked[index].diagnosticEvidence.append("duplicate-label:\(label)")
            }
        }
        return linked.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func mergedState(
        _ lhs: StartupItemsDomain.State,
        _ rhs: StartupItemsDomain.State
    ) -> StartupItemsDomain.State {
        StartupItemsDomain.State(
            registration: rhs.registration == .unknown ? lhs.registration : rhs.registration,
            authorization: rhs.authorization == .unknown ? lhs.authorization : rhs.authorization,
            enablement: rhs.enablement == .unknown ? lhs.enablement : rhs.enablement,
            load: rhs.load == .unknown ? lhs.load : rhs.load,
            process: rhs.process == .unknown ? lhs.process : rhs.process,
            management: managementPriority(rhs.management) > managementPriority(lhs.management)
                ? rhs.management
                : lhs.management
        )
    }

    private static func managementPriority(
        _ value: StartupItemsDomain.ManagementState
    ) -> Int {
        switch value {
        case .systemProtected: 7
        case .managedByOrganization: 6
        case .requiresAdministrator: 5
        case .manageableInSystemSettings: 4
        case .readOnly: 3
        case .unsupported: 2
        case .directlyManageable: 1
        }
    }

    private static func shouldMerge(
        _ lhs: MergeFingerprint,
        _ rhs: MergeFingerprint
    ) -> Bool {
        if lhs.isOrphaned || rhs.isOrphaned {
            return lhs.isOrphaned == rhs.isOrphaned && lhs.id == rhs.id
        }
        if let leftPlist = lhs.plistPath,
           let rightPlist = rhs.plistPath {
            return leftPlist == rightPlist
        }
        guard lhs.label == rhs.label, lhs.label != nil else { return false }
        if let leftExecutable = lhs.executablePath,
           let rightExecutable = rhs.executablePath,
           leftExecutable == rightExecutable { return true }
        return lhs.reliableApplicationIdentity != nil
            && lhs.reliableApplicationIdentity == rhs.reliableApplicationIdentity
    }

    private static func sourcePriority(_ source: StartupItemsDomain.ScanSource) -> Int {
        switch source {
        case .launchdPlist: 0
        case .openAtLogin: 1
        case .serviceManagement, .backgroundTaskDiagnostic: 2
        case .embeddedService, .privilegedHelper: 3
        default: 4
        }
    }
}

struct StartupItemMerger: Sendable {
    func merge(_ candidates: [StartupItemsDomain.Candidate]) -> [StartupItemsDomain.Item] {
        let grouped = Dictionary(grouping: candidates, by: groupIdentifier)
        return grouped.map { identifier, components in
            let sortedComponents = components.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let primary = sortedComponents.max { lhs, rhs in
                (lhs.attribution?.confidence ?? .unknown) < (rhs.attribution?.confidence ?? .unknown)
            } ?? sortedComponents[0]
            let duplicateLabels = Dictionary(grouping: sortedComponents.compactMap(\.label), by: { $0 })
                .filter { $0.value.count > 1 }
                .keys
            var warnings = Set(sortedComponents.flatMap(\.diagnosticEvidence).filter {
                $0.contains("missing") || $0.contains("writable") || $0.contains("invalid")
                    || $0.contains("orphan") || $0.contains("duplicate-label")
            })
            duplicateLabels.forEach { warnings.insert("duplicate-label:\($0)") }
            let aggregateAction = actionCapability(for: sortedComponents)

            return StartupItemsDomain.Item(
                id: identifier,
                kind: primary.kind,
                scope: primary.scope,
                name: (primary.attribution?.confidence ?? .unknown) >= .high
                    ? (primary.attribution?.applicationName ?? primary.name)
                    : primary.name,
                components: sortedComponents,
                state: aggregateState(for: sortedComponents),
                attribution: primary.attribution,
                actionCapability: aggregateAction,
                warnings: warnings.sorted()
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func groupIdentifier(_ candidate: StartupItemsDomain.Candidate) -> String {
        if let identity = candidate.reliableApplicationIdentity {
            return "application:\(identity)"
        }
        if candidate.kind == .orphanedItem,
           let sourceEvidence = candidate.diagnosticEvidence.first(where: { $0.hasPrefix("source-candidate:") }) {
            return "component:\(sourceEvidence.dropFirst("source-candidate:".count))"
        }
        return "component:\(candidate.id)"
    }

    private func aggregateState(for components: [StartupItemsDomain.Candidate]) -> StartupItemsDomain.State {
        let states = components.map(\.state)
        return StartupItemsDomain.State(
            registration: states.map(\.registration).max(by: {
                registrationPriority($0) < registrationPriority($1)
            }) ?? .unknown,
            authorization: states.map(\.authorization).max(by: {
                authorizationPriority($0) < authorizationPriority($1)
            }) ?? .unknown,
            enablement: states.map(\.enablement).max(by: {
                enablementPriority($0) < enablementPriority($1)
            }) ?? .unknown,
            load: states.map(\.load).max(by: { loadPriority($0) < loadPriority($1) }) ?? .unknown,
            process: states.map(\.process).max(by: { processPriority($0) < processPriority($1) }) ?? .unknown,
            management: states.map(\.management).max(by: {
                managementPriority($0) < managementPriority($1)
            }) ?? .unsupported
        )
    }

    private func registrationPriority(_ value: StartupItemsDomain.RegistrationState) -> Int {
        switch value { case .registered: 4; case .legacyRegistered: 3; case .discoveredFromFile: 2; case .notRegistered: 1; case .unknown: 0 }
    }

    private func authorizationPriority(_ value: StartupItemsDomain.AuthorizationState) -> Int {
        switch value { case .managed: 6; case .denied: 5; case .requiresApproval: 4; case .approved: 3; case .notApplicable: 2; case .unknown: 0 }
    }

    private func enablementPriority(_ value: StartupItemsDomain.EnablementState) -> Int {
        switch value { case .disabled: 4; case .temporarilyStopped: 3; case .enabled: 2; case .unknown: 0 }
    }

    private func loadPriority(_ value: StartupItemsDomain.LoadState) -> Int {
        switch value { case .loaded: 4; case .onDemand: 3; case .notLoaded: 2; case .unavailable: 1; case .unknown: 0 }
    }

    private func processPriority(_ value: StartupItemsDomain.ProcessState) -> Int {
        switch value { case .running: 5; case .waiting: 4; case .failed: 3; case .stopped: 2; case .unknown: 0 }
    }

    private func managementPriority(_ value: StartupItemsDomain.ManagementState) -> Int {
        switch value { case .systemProtected: 7; case .managedByOrganization: 6; case .requiresAdministrator: 5; case .manageableInSystemSettings: 4; case .readOnly: 3; case .unsupported: 2; case .directlyManageable: 1 }
    }

    private func actionCapability(
        for components: [StartupItemsDomain.Candidate]
    ) -> StartupItemsDomain.ActionCapability {
        let actions = components.map(\.actionCapability)
        return StartupItemsDomain.ActionCapability(
            canEnableDirectly: !actions.isEmpty && actions.allSatisfy(\.canEnableDirectly),
            canDisableDirectly: !actions.isEmpty && actions.allSatisfy(\.canDisableDirectly),
            canStopCurrentSession: actions.contains(where: \.canStopCurrentSession),
            canOpenSystemSettings: actions.contains(where: \.canOpenSystemSettings),
            canRevealInFinder: actions.contains(where: \.canRevealInFinder),
            canOpenParentApp: actions.contains(where: \.canOpenParentApp)
                && components.contains(where: \.hasAuthoritativeParentApplication),
            canRemoveOrphan: !actions.isEmpty && actions.allSatisfy(\.canRemoveOrphan),
            requiresAdministrator: actions.contains(where: \.requiresAdministrator),
            isReadOnly: actions.allSatisfy(\.isReadOnly),
            isManaged: actions.contains(where: \.isManaged)
        )
    }
}
