import Darwin
import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacMiniPolicyStoreTests: XCTestCase {
    private let identity = MacMiniApplicationIdentity(installationPath: "/Applications/App.app", signingIdentity: "team:A")

    func testPrivateArchiveRoundTripAndCleanOffRemovesBothRecords() throws {
        let root = try fixture()
        let store = try makeStore(root)
        let enabled = MacMiniPersistedState(mode: .whenOnAC, ownsSleepDisabled: true)
        try store.save(enabled)
        XCTAssertEqual(store.load().state, enabled)
        XCTAssertNil(store.load().reason)
        let policy = root.appendingPathComponent("policy.json")
        let recovery = root.appendingPathComponent("recovery.json")
        XCTAssertEqual(try mode(policy), 0o600)
        XCTAssertEqual(try mode(recovery), 0o600)
        XCTAssertTrue(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid()))
        try store.save(.init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: policy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertFalse(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid()))
    }

    func testInvalidDirectoryDegradesWithoutThrowOrOwnershipGuess() throws {
        for permissions in [0o755, 0o777, 0o1700] {
            let root = try fixture()
            try writeRecord(.init(mode: .whenOnAC, ownsSleepDisabled: true), root: root, name: "policy.json")
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path)
            let bootstrap = MacMiniPolicyStore.openOrDegrade(directoryURL: root, application: identity, trustedOwner: geteuid())
            XCTAssertNil(bootstrap.store)
            XCTAssertEqual(bootstrap.load.state, .init())
            XCTAssertTrue(bootstrap.load.persistenceUnavailable)
            XCTAssertTrue(bootstrap.load.reason?.contains("permissions rejected") == true)
            // Bootstrap returns normally; the helper can create its other services.
            var commands: [MacMiniPMSetCommand] = []
            let engine = MacMiniModeEngine(state: bootstrap.load.state,
                read: { .init(powerSource: .ac, sleepDisabled: true, clamshellClosed: true, clamshellCausesSleep: true) },
                execute: { commands.append($0); return true }, persist: { _ in throw MacMiniModeFailure.persistenceFailed },
                persistenceUnavailable: bootstrap.load.persistenceUnavailable)
            XCTAssertEqual(engine.reconcile().mode, .off)
            XCTAssertEqual(engine.setMode(.whenOnAC).failure, .persistenceFailed)
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testCorruptPolicyWithoutTrustedJournalIsOffAndQuarantined() throws {
        let root = try fixture()
        try write(Data("not JSON".utf8), root: root, name: "policy.json")
        let loaded = try makeStore(root).load()
        XCTAssertEqual(loaded.state, .init())
        XCTAssertTrue(loaded.persistenceUnavailable)
        XCTAssertTrue(loaded.reason?.contains("quarantined=true") == true)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("policy.damaged-") }.count, 1)
        XCTAssertFalse(names.contains("policy.json"))
        XCTAssertEqual(try makeStore(root).load().state, .init())
        XCTAssertNil(try makeStore(root).load().reason)
    }

    func testUnsafePolicyCannotBeTrustedButIndependentJournalCanRecover() throws {
        for corrupt in [false, true] {
            let root = try fixture()
            let store = try makeStore(root)
            try store.save(.init(mode: .whenOnAC, ownsSleepDisabled: true))
            if corrupt {
                try write(Data("broken".utf8), root: root, name: "policy.json")
            } else {
                try FileManager.default.setAttributes([.posixPermissions: 0o644],
                    ofItemAtPath: root.appendingPathComponent("policy.json").path)
            }
            let loaded = store.load()
            XCTAssertEqual(loaded.state.mode, .off)
            XCTAssertTrue(loaded.state.ownsSleepDisabled)
            XCTAssertTrue(loaded.persistenceUnavailable)
            var disabled = true
            var commands: [MacMiniPMSetCommand] = []
            let engine = MacMiniModeEngine(state: loaded.state,
                read: { .init(powerSource: .ac, sleepDisabled: disabled, clamshellClosed: true, clamshellCausesSleep: true) },
                execute: { command in
                    commands.append(command)
                    if case .disableSleep(let value) = command { disabled = value }
                    return true
                }, persist: { try store.save($0) }, persistenceUnavailable: loaded.persistenceUnavailable)
            let status = engine.reconcile()
            XCTAssertEqual(commands, [.disableSleep(false)])
            XCTAssertFalse(status.ownsSleepDisabled)
            XCTAssertFalse(status.readings.sleepDisabled ?? true)
            XCTAssertEqual(status.failure, .persistenceFailed)
        }
    }

    func testUntrustedRecoveryOrFutureVersionCannotInventOwnership() throws {
        for problem in ["permissions", "corrupt", "future"] {
            let root = try fixture()
            try write(Data("broken policy".utf8), root: root, name: "policy.json")
            try writeRecord(.init(ownsSleepDisabled: true), root: root, name: "recovery.json")
            if problem == "permissions" {
                try FileManager.default.setAttributes([.posixPermissions: 0o644],
                    ofItemAtPath: root.appendingPathComponent("recovery.json").path)
            } else if problem == "corrupt" {
                try write(Data("broken journal".utf8), root: root, name: "recovery.json")
            } else {
                let data = try Data(contentsOf: root.appendingPathComponent("recovery.json"))
                let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"version\":2", with: "\"version\":99")
                try write(Data(text.utf8), root: root, name: "recovery.json")
            }
            let loaded = try makeStore(root).load()
            XCTAssertEqual(loaded.state, .init(), problem)
            XCTAssertTrue(loaded.persistenceUnavailable)
        }
    }

    func testLinksNeverSupplyOwnershipAndTargetsStayUnchanged() throws {
        for hard in [false, true] {
            let root = try fixture()
            let target = root.appendingPathComponent("original.json")
            let original = try JSONEncoder().encode(MacMiniPolicyRecord(application: identity,
                state: .init(mode: .whenOnAC, ownsSleepDisabled: true)))
            try write(original, root: root, name: "original.json")
            let policy = root.appendingPathComponent("policy.json")
            if hard { XCTAssertEqual(link(target.path, policy.path), 0) }
            else { try FileManager.default.createSymbolicLink(at: policy, withDestinationURL: target) }
            let loaded = try makeStore(root).load()
            XCTAssertEqual(loaded.state, .init())
            XCTAssertTrue(loaded.persistenceUnavailable)
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testSymlinkDirectoryDegradesAndDoesNotFollowIt() throws {
        let root = try fixture()
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try writeRecord(.init(mode: .whenOnAC, ownsSleepDisabled: true), root: target, name: "policy.json")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let loaded = MacMiniPolicyStore.openOrDegrade(directoryURL: link, application: identity, trustedOwner: geteuid())
        XCTAssertNil(loaded.store)
        XCTAssertEqual(loaded.load.state, .init())
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("policy.json").path))
    }

    func testSameSignedInstallationRetainsIntentAcrossBundleReplacement() throws {
        let root = try fixture()
        let app = root.appendingPathComponent("App.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let binding = MacMiniApplicationIdentity(installationPath: app.path, signingIdentity: "team:A")
        let store = try MacMiniPolicyStore(directoryURL: root, application: binding, trustedOwner: geteuid())
        let state = MacMiniPersistedState(mode: .whenOnAC, ownsSleepDisabled: true)
        try store.save(state)
        try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("old.app"))
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let afterUpdate = try MacMiniPolicyStore(directoryURL: root, application: binding, trustedOwner: geteuid()).load()
        XCTAssertEqual(afterUpdate.state, state)
        XCTAssertNil(afterUpdate.reason)
        let encoded = String(decoding: try Data(contentsOf: root.appendingPathComponent("policy.json")), as: UTF8.self)
        XCTAssertFalse(encoded.contains("applicationDevice"))
        XCTAssertFalse(encoded.contains("applicationInode"))
    }

    func testMovedPathOrSigningChangeClearsIntentButRetainsTrustedDebt() throws {
        for replacement in [MacMiniApplicationIdentity(installationPath: "/Moved/App.app", signingIdentity: "team:A"),
                            MacMiniApplicationIdentity(installationPath: identity.installationPath, signingIdentity: "team:B")] {
            let root = try fixture()
            try makeStore(root).save(.init(mode: .whenOnAC, ownsSleepDisabled: true))
            let next = try MacMiniPolicyStore(directoryURL: root, application: replacement, trustedOwner: geteuid()).load()
            XCTAssertEqual(next.state.mode, .off)
            XCTAssertTrue(next.state.ownsSleepDisabled)
            XCTAssertNil(next.reason)
        }
    }

    func testLegacyIntentMigratesOffOnceWithOnlyTrustedRecoveryDebt() throws {
        let root = try fixture()
        try write(Data("{\"version\":1,\"applicationDevice\":1,\"applicationInode\":2,\"state\":{\"mode\":\"whenOnAC\",\"ownsSleepDisabled\":true}}".utf8),
            root: root, name: "policy.json")
        let store = try makeStore(root)
        XCTAssertEqual(store.load().state, .init(ownsSleepDisabled: true))
        let migrated = try JSONDecoder().decode(MacMiniPolicyRecord.self, from: Data(contentsOf: root.appendingPathComponent("policy.json")))
        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.application, identity)
        XCTAssertEqual(migrated.state.mode, .off)
    }

    func testSiblingHoldingCoversIntentRecoveryAndRejectsUnsafeArchive() throws {
        let root = try fixture()
        XCTAssertFalse(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid()))
        try writeRecord(.init(mode: .whenOnAC), root: root, name: "policy.json")
        XCTAssertTrue(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid()))
        try FileManager.default.removeItem(at: root.appendingPathComponent("policy.json"))
        try writeRecord(.init(ownsSleepDisabled: true), root: root, name: "recovery.json")
        XCTAssertTrue(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid()))
        try write(Data("broken".utf8), root: root, name: "recovery.json")
        XCTAssertThrowsError(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid()))
    }

    func testSharedLockSerializesTwoIdentitiesAndReleasesWithoutBlocking() throws {
        let root = try fixture()
        let releaseLock = try MacMiniPolicyLock(directoryURL: root, trustedOwner: geteuid())
        let betaLock = try MacMiniPolicyLock(directoryURL: root, trustedOwner: geteuid())
        XCTAssertTrue(releaseLock.acquire(pause: { _ in }))
        defer { releaseLock.release(); betaLock.release() }
        XCTAssertFalse(betaLock.acquire(pause: { _ in }))
        releaseLock.release()
        XCTAssertTrue(betaLock.acquire(pause: { _ in }))
        XCTAssertFalse(releaseLock.acquire(pause: { _ in }))
    }

    func testReleaseAndBetaCannotBothEnableAndCanHandOverAfterOff() throws {
        let root = try fixture()
        let releaseURL = root.appendingPathComponent("Release")
        let betaURL = root.appendingPathComponent("Beta")
        let lockURL = root.appendingPathComponent("Lock")
        let releaseStore = try makeStore(releaseURL)
        let betaStore = try MacMiniPolicyStore(directoryURL: betaURL,
            application: .init(installationPath: "/Beta.app", signingIdentity: "team:A"), trustedOwner: geteuid())
        let releaseLock = try MacMiniPolicyLock(directoryURL: lockURL, trustedOwner: geteuid())
        let betaLock = try MacMiniPolicyLock(directoryURL: lockURL, trustedOwner: geteuid())
        var disabled = false
        var commands: [MacMiniPMSetCommand] = []
        let read: () -> MacMiniSystemReadings = {
            .init(powerSource: .ac, sleepDisabled: disabled, clamshellClosed: false, clamshellCausesSleep: true)
        }
        let execute: (MacMiniPMSetCommand) -> Bool = { command in
            commands.append(command)
            if case .disableSleep(let value) = command { disabled = value }
            return true
        }
        let releaseEngine = MacMiniModeEngine(state: .init(), read: read, execute: execute, persist: { try releaseStore.save($0) })
        let betaEngine = MacMiniModeEngine(state: .init(), read: read, execute: execute, persist: { try betaStore.save($0) })
        let release = MacMiniModeLifecycle(engine: releaseEngine, installationIsValid: { true },
            otherIdentityIsHolding: { try MacMiniPolicyStore.isHolding(directoryURL: betaURL, trustedOwner: geteuid()) },
            hardwareIsSupported: { true }, acquire: { releaseLock.acquire(pause: { _ in }) }, release: { releaseLock.release() })
        let beta = MacMiniModeLifecycle(engine: betaEngine, installationIsValid: { true },
            otherIdentityIsHolding: { try MacMiniPolicyStore.isHolding(directoryURL: releaseURL, trustedOwner: geteuid()) },
            hardwareIsSupported: { true }, acquire: { betaLock.acquire(pause: { _ in }) }, release: { betaLock.release() })
        XCTAssertNil(release.setMode(.whenOnAC).failure)
        XCTAssertEqual(beta.setMode(.whenOnAC).failure, .conflictingIdentity)
        XCTAssertEqual(betaEngine.state.mode, .off)
        XCTAssertEqual(betaStore.load().state, .init())
        XCTAssertEqual(commands, [.disableSleep(true)])
        XCTAssertNil(release.setMode(.off).failure)
        XCTAssertNil(beta.setMode(.whenOnAC).failure)
        XCTAssertEqual(commands, [.disableSleep(true), .disableSleep(false), .disableSleep(true)])
        XCTAssertEqual(releaseStore.load().state, .init())
        XCTAssertEqual(betaStore.load().state.mode, .whenOnAC)
    }

    func testUnknownSigningAtLoadPreservesIntentAndArchiveBytes() throws {
        let root = try fixture()
        let state = MacMiniPersistedState(mode: .whenOnAC, ownsSleepDisabled: true)
        try makeStore(root).save(state)
        let policy = root.appendingPathComponent("policy.json")
        let before = try Data(contentsOf: policy)
        let uncertain = try MacMiniPolicyStore(directoryURL: root, application: nil, trustedOwner: geteuid())
        let loaded = uncertain.load()
        XCTAssertEqual(loaded.state, state)
        XCTAssertNil(loaded.reason)
        XCTAssertEqual(try Data(contentsOf: policy), before)
        // Trusted archive binding may only be adopted for subsequent recovery.
        try uncertain.save(.init(ownsSleepDisabled: true))
        let recovered = try JSONDecoder().decode(MacMiniPolicyRecord.self, from: Data(contentsOf: policy))
        XCTAssertEqual(recovered.application, identity)
        XCTAssertEqual(recovered.state.mode, .off)

        let emptyRoot = try fixture()
        let unbound = try MacMiniPolicyStore(directoryURL: emptyRoot, application: nil, trustedOwner: geteuid())
        try unbound.save(.init())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: emptyRoot.path).isEmpty)
        XCTAssertThrowsError(try unbound.save(.init(mode: .whenOnAC)))

        let legacyRoot = try fixture()
        let legacyBytes = Data("{\"version\":1,\"state\":{\"mode\":\"whenOnAC\",\"ownsSleepDisabled\":true}}".utf8)
        try write(legacyBytes, root: legacyRoot, name: "policy.json")
        let legacy = try MacMiniPolicyStore(directoryURL: legacyRoot, application: nil, trustedOwner: geteuid())
        let legacyLoad = legacy.load()
        XCTAssertEqual(legacyLoad.state, .init(ownsSleepDisabled: true))
        XCTAssertNil(legacyLoad.reason, "A trusted legacy recovery is usable while migration waits")
        let legacyPolicy = legacyRoot.appendingPathComponent("policy.json")
        XCTAssertEqual(try Data(contentsOf: legacyPolicy), legacyBytes)
        var disabled = true
        var canRestore = false
        var commands: [MacMiniPMSetCommand] = []
        let engine = MacMiniModeEngine(state: legacyLoad.state,
            read: { .init(powerSource: .ac, sleepDisabled: disabled, clamshellClosed: true, clamshellCausesSleep: true) },
            execute: { command in
                commands.append(command)
                guard canRestore else { return false }
                if case .disableSleep(let value) = command { disabled = value }
                return true
            }, persist: { try legacy.save($0) })
        XCTAssertEqual(engine.prepareForTermination().failure, .commandFailed)
        XCTAssertEqual(try Data(contentsOf: legacyPolicy), legacyBytes)
        canRestore = true
        let restored = engine.disableForRemoval()
        XCTAssertNil(restored.failure)
        XCTAssertFalse(restored.ownsSleepDisabled)
        XCTAssertEqual(commands, [.disableSleep(false), .disableSleep(false)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPolicy.path))
    }

    func testMissingOrMismatchedPeerIsFreeButUnknownStillReserves() throws {
        let root = try fixture()
        try makeStore(root).save(.init(mode: .whenOnAC, ownsSleepDisabled: true))
        let before = try Data(contentsOf: root.appendingPathComponent("policy.json"))
        var checked: [MacMiniApplicationIdentity] = []
        XCTAssertFalse(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid(),
            validateApplication: { checked.append($0); return false }))
        XCTAssertEqual(checked, [identity, identity], "Inspect both intent and recovery binding")
        XCTAssertTrue(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid(),
            validateApplication: { _ in nil }), "Unknown signing is not evidence of a free peer")
        XCTAssertTrue(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid(),
            validateApplication: { _ in true }))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("policy.json")), before,
            "Inspection must not erase the other version's evidence")
    }

    func testContendedBootLockRetriesThenLoadsExistingEnabledIntent() throws {
        let root = try fixture()
        let store = try makeStore(root)
        let state = MacMiniPersistedState(mode: .whenOnAC, ownsSleepDisabled: true)
        try store.save(state)
        let first = try MacMiniPolicyLock(directoryURL: root.appendingPathComponent("Lock"), trustedOwner: geteuid())
        let second = try MacMiniPolicyLock(directoryURL: root.appendingPathComponent("Lock"), trustedOwner: geteuid())
        XCTAssertTrue(first.acquire(pause: { _ in }))
        defer { first.release(); second.release() }
        var waits: [TimeInterval] = []
        let bootstrap = MacMiniDeferredBootstrap<MacMiniPolicyLoad>(acquire: {
            second.acquire(pause: { delay in
                waits.append(delay)
                if waits.count == 2 { first.release() }
            })
        }, release: { second.release() }, load: { store.load() })
        XCTAssertEqual(bootstrap.retry()?.state, state)
        XCTAssertEqual(waits, [0.05, 0.10])
        XCTAssertFalse(bootstrap.isPending)
        XCTAssertEqual(store.load().state, state)
    }

    func testPeerHoldingTracksActualBundleRemovalAndSigningMismatch() throws {
        let root = try fixture()
        let app = root.appendingPathComponent("Peer.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let binding = MacMiniApplicationIdentity(installationPath: app.path, signingIdentity: "team:Peer")
        let store = try MacMiniPolicyStore(directoryURL: root, application: binding, trustedOwner: geteuid())
        try store.save(.init(mode: .whenOnAC, ownsSleepDisabled: true))
        let before = try Data(contentsOf: root.appendingPathComponent("policy.json"))
        var signed: Bool? = true
        let validator = MacMiniApplicationValidation(metadata: MacMiniApplicationValidation.readMetadata,
            verify: { _, _ in signed })
        func isHolding() throws -> Bool {
            try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid(),
                validateApplication: { validator.validate($0, identifier: "peer") })
        }
        XCTAssertTrue(try isHolding())
        try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("Moved.app"))
        XCTAssertFalse(try isHolding(), "A genuinely absent installation cannot reserve intent forever")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        signed = false
        XCTAssertFalse(try isHolding(), "A confirmed signature mismatch no longer holds")
        signed = nil
        validator.invalidate()
        XCTAssertTrue(try isHolding(), "An intermittent signature failure is not a confirmed mismatch")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("policy.json")), before)
    }

    func testLegacyPeerClaimsExpireWithoutDeletingProofOrHidingCurrentClaims() throws {
        for name in ["policy.json", "recovery.json"] {
            let root = try fixture()
            let legacy = Data("{\"version\":1,\"state\":{\"mode\":\"whenOnAC\",\"ownsSleepDisabled\":true}}".utf8)
            try write(legacy, root: root, name: name)
            var validations = 0
            XCTAssertFalse(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid(),
                validateApplication: { _ in validations += 1; return true }))
            XCTAssertEqual(validations, 0, "A legacy claim has no installation to validate")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), legacy)
            // Expiring one old claim must not hide the other, current record.
            let otherName = name == "policy.json" ? "recovery.json" : "policy.json"
            try writeRecord(.init(ownsSleepDisabled: true), root: root, name: otherName)
            XCTAssertTrue(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid(),
                validateApplication: { _ in validations += 1; return true }))
            XCTAssertEqual(validations, 1)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), legacy)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("policy.json").path)
            XCTAssertThrowsError(try MacMiniPolicyStore.isHolding(directoryURL: root, trustedOwner: geteuid()),
                                 "Unknown unsafe data is not a validated legacy claim")
        }
    }

    func testInvalidLockDirectoryStillAllowsTrustedRecoveryAndKeepsArchivesIntact() throws {
        for permissions in [0o755, 0o777, 0o1700] {
            let root = try fixture()
            let own = root.appendingPathComponent("Own")
            let lock = root.appendingPathComponent("Lock")
            let store = try makeStore(own)
            try store.save(.init(mode: .whenOnAC, ownsSleepDisabled: true))
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: lock.path)
            XCTAssertThrowsError(try MacMiniPolicyLock(directoryURL: lock, trustedOwner: geteuid()))
            let policyBefore = try Data(contentsOf: own.appendingPathComponent("policy.json"))
            let recoveryBefore = try Data(contentsOf: own.appendingPathComponent("recovery.json"))
            let loaded = MacMiniPolicyStore.readRecoveryWithoutLock(directoryURL: own, trustedOwner: geteuid())
            XCTAssertEqual(loaded.state, .init(ownsSleepDisabled: true))
            XCTAssertTrue(loaded.persistenceUnavailable)
            XCTAssertTrue(loaded.reason?.contains("read-only trusted recovery=true") == true)
            var disabled = true
            var commands: [MacMiniPMSetCommand] = []
            let engine = MacMiniModeEngine(state: loaded.state,
                read: { .init(powerSource: .ac, sleepDisabled: disabled, clamshellClosed: true, clamshellCausesSleep: true) },
                execute: { command in
                    commands.append(command)
                    if case .disableSleep(let value) = command { disabled = value }
                    return true
                }, persist: { _ in XCTFail("No archive mutation without the shared lock") },
                persistenceUnavailable: loaded.persistenceUnavailable)
            let lifecycle = MacMiniModeLifecycle(engine: engine, installationIsValid: { nil },
                otherIdentityIsHolding: { XCTFail("No peer inspection without the lock"); return true },
                hardwareIsSupported: { nil }, acquire: { false }, release: { XCTFail("Lock was not acquired") })
            for action in ["reconcile", "off", "removal", "termination"] {
                disabled = true
                let result: MacMiniModeStatus
                switch action {
                case "off": result = lifecycle.setMode(.off)
                case "removal": result = lifecycle.disableForRemoval()
                case "termination": result = lifecycle.prepareForTermination()
                default: result = lifecycle.reconcile()
                }
                XCTAssertEqual(result.readings.sleepDisabled, false)
                XCTAssertEqual(result.failure, .persistenceFailed)
                XCTAssertTrue(result.ownsSleepDisabled, "Keep proof for later locked cleanup")
            }
            XCTAssertEqual(commands, Array(repeating: .disableSleep(false), count: 4))
            XCTAssertEqual(lifecycle.setMode(.whenOnAC).failure, .persistenceFailed)
            XCTAssertEqual(commands.count, 4)
            XCTAssertEqual(try Data(contentsOf: own.appendingPathComponent("policy.json")), policyBefore)
            XCTAssertEqual(try Data(contentsOf: own.appendingPathComponent("recovery.json")), recoveryBefore)
            XCTAssertEqual(try mode(lock), permissions, "Do not silently repair an unknown directory")
        }
    }

    func testLocklessRecoveryReadsOnlyTrustedOwnDebtIncludingLegacyWithoutMigration() throws {
        for version in [1, 2] {
            for name in ["policy.json", "recovery.json"] {
                for owns in [false, true] {
                    let root = try fixture()
                    let state = MacMiniPersistedState(mode: .whenOnAC, ownsSleepDisabled: owns)
                    let bytes: Data
                    if version == 1 {
                        bytes = Data("{\"version\":1,\"state\":{\"mode\":\"whenOnAC\",\"ownsSleepDisabled\":\(owns)}}".utf8)
                    } else {
                        bytes = try JSONEncoder().encode(MacMiniPolicyRecord(application: identity, state: state))
                    }
                    try write(bytes, root: root, name: name)
                    let result = MacMiniPolicyStore.readRecoveryWithoutLock(directoryURL: root, trustedOwner: geteuid())
                    XCTAssertEqual(result.state, .init(ownsSleepDisabled: owns))
                    XCTAssertTrue(result.persistenceUnavailable)
                    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), bytes)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [name])
                }
            }
        }
        let root = try fixture()
        let missing = root.appendingPathComponent("Missing")
        XCTAssertEqual(MacMiniPolicyStore.readRecoveryWithoutLock(directoryURL: missing, trustedOwner: geteuid()).state, .init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "Read-only fallback never creates a directory")
    }

    func testLocklessRecoveryRejectsUnsafeProofButCanUseIndependentJournal() throws {
        for problem in ["directory", "permissions", "corrupt", "future", "binding", "symlink", "hardlink"] {
            let root = try fixture()
            let original = try JSONEncoder().encode(MacMiniPolicyRecord(application: identity,
                state: .init(mode: .whenOnAC, ownsSleepDisabled: true)))
            for name in ["policy.json", "recovery.json"] {
                try write(original, root: root, name: name)
                let path = root.appendingPathComponent(name)
                switch problem {
                case "permissions": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
                case "corrupt": try write(Data("broken".utf8), root: root, name: name)
                case "future":
                    try write(Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"version\":2", with: "\"version\":99").utf8), root: root, name: name)
                case "binding":
                    try write(Data("{\"version\":2,\"state\":{\"mode\":\"whenOnAC\",\"ownsSleepDisabled\":true}}".utf8), root: root, name: name)
                case "symlink", "hardlink":
                    let target = root.appendingPathComponent("target-\(name)")
                    try FileManager.default.moveItem(at: path, to: target)
                    if problem == "symlink" { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target) }
                    else { XCTAssertEqual(link(target.path, path.path), 0) }
                default: break
                }
            }
            if problem == "directory" { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
            let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            let result = MacMiniPolicyStore.readRecoveryWithoutLock(directoryURL: root, trustedOwner: geteuid())
            XCTAssertEqual(result.state, .init(), problem)
            XCTAssertTrue(result.persistenceUnavailable)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
            var commands: [MacMiniPMSetCommand] = []
            let engine = MacMiniModeEngine(state: result.state,
                read: { .init(powerSource: .battery, sleepDisabled: true, clamshellClosed: true, clamshellCausesSleep: true) },
                execute: { commands.append($0); return true }, persist: { _ in XCTFail("No untrusted save") },
                persistenceUnavailable: true)
            _ = engine.recoverWithoutPersistence()
            XCTAssertTrue(commands.isEmpty, "A system 1 cannot invent ownership: \(problem)")
        }
        let root = try fixture()
        let corrupt = Data("broken intent".utf8)
        try write(corrupt, root: root, name: "policy.json")
        try writeRecord(.init(ownsSleepDisabled: true), root: root, name: "recovery.json")
        XCTAssertTrue(MacMiniPolicyStore.readRecoveryWithoutLock(directoryURL: root, trustedOwner: geteuid()).state.ownsSleepDisabled)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("policy.json")), corrupt,
                       "Fallback cannot quarantine or rewrite evidence")
    }

    func testLocklessRecoveryHonorsCommittedClearBeforeStaleJournal() throws {
        let root = try fixture()
        try writeRecord(.init(mode: .whenOnAC), root: root, name: "policy.json")
        try writeRecord(.init(mode: .whenOnAC, ownsSleepDisabled: true), root: root, name: "recovery.json")
        let loaded = MacMiniPolicyStore.readRecoveryWithoutLock(directoryURL: root, trustedOwner: geteuid())
        XCTAssertEqual(loaded.state, .init(), "Committed clear wins over a journal awaiting deletion")
        var commands: [MacMiniPMSetCommand] = []
        let engine = MacMiniModeEngine(state: loaded.state,
            read: { .init(powerSource: .battery, sleepDisabled: true, clamshellClosed: true, clamshellCausesSleep: true) },
            execute: { commands.append($0); return true }, persist: { _ in XCTFail("No unlocked save") },
            persistenceUnavailable: true)
        _ = engine.recoverWithoutPersistence()
        XCTAssertTrue(commands.isEmpty, "A later external or peer 1 must not be cleared using stale proof")
    }

    private func fixture() throws -> URL {
        let root = TestFileSystem.uniqueRoot("MacMiniPolicy")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func makeStore(_ root: URL) throws -> MacMiniPolicyStore {
        try MacMiniPolicyStore(directoryURL: root, application: identity, trustedOwner: geteuid())
    }

    private func writeRecord(_ state: MacMiniPersistedState, root: URL, name: String) throws {
        try write(JSONEncoder().encode(MacMiniPolicyRecord(application: identity, state: state)), root: root, name: name)
    }

    private func write(_ data: Data, root: URL, name: String) throws {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
