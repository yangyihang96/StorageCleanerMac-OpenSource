import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateFreshActualTargetTests: XCTestCase {
    func testHomebrewCaskFreshBeforeAndAfterReadsExactTargetDespiteWarmDisplayCache() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let inspector = AppUpdateCountingSignatureInspector()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let display = makeDisplay(root: root, raw: raw)
        _ = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        _ = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        let recorder = AppUpdateFreshCallRecorder()
        let provider = homebrew(raw: raw, recorder: recorder) {
            try AppUpdatePerformanceTestSupport.writeInfo(at: url, version: "2.0")
        }
        let application = AppUpdateTestFixtures.strictHomebrewApplication(path: url.path)
        let prepared = try await provider.prepareUpdate(application)
        let result = try await provider.install(prepared) { _ in }
        XCTAssertEqual(result.state, .needsReconciliation)
        XCTAssertEqual(recorder.paths, [url, url])
        XCTAssertEqual(recorder.commands, 1)
        let count = await raw.count
        let signatures = await inspector.paths.count
        XCTAssertEqual(count, 3, "One cold display read plus two mandatory fresh execution reads")
        XCTAssertEqual(signatures, 3)
    }

    func testHomebrewCaskRejectsSameVersionResourceChangeBeforeCommand() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let inspector = AppUpdateCountingSignatureInspector()
        await inspector.requireUnchangedResource()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let display = makeDisplay(root: root, raw: raw)
        _ = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        let application = AppUpdateTestFixtures.strictHomebrewApplication(path: url.path)
        let recorder = AppUpdateFreshCallRecorder()
        let provider = homebrew(raw: raw, recorder: recorder) {}
        let prepared = try await provider.prepareUpdate(application)
        try Data("resource-b".utf8).write(to: url.appendingPathComponent("Contents/Resources/payload"))
        do {
            _ = try await provider.install(prepared) { _ in }
            XCTFail("Same version does not authorize a changed actual target")
        } catch ProviderBackedUpdateExecutorError.applicationIdentityChanged { }
        XCTAssertEqual(recorder.commands, 0)
        XCTAssertEqual(recorder.paths, [url])
        let count = await raw.count
        XCTAssertEqual(count, 2)
    }

    func testHomebrewCaskRejectsSameVersionResourceChangeAfterCommand() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let inspector = AppUpdateCountingSignatureInspector()
        await inspector.requireUnchangedResource()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let recorder = AppUpdateFreshCallRecorder()
        let provider = homebrew(raw: raw, recorder: recorder) {
            try Data("resource-b".utf8).write(to: url.appendingPathComponent("Contents/Resources/payload"))
        }
        let application = AppUpdateTestFixtures.strictHomebrewApplication(path: url.path)
        let prepared = try await provider.prepareUpdate(application)
        do {
            _ = try await provider.install(prepared) { _ in }
            XCTFail("A changed same-version target must fail fresh postflight")
        } catch ProviderBackedUpdateExecutorError.applicationIdentityChanged { }
        XCTAssertEqual(recorder.commands, 1)
        XCTAssertEqual(recorder.paths, [url, url])
        let count = await raw.count
        XCTAssertEqual(count, 2)
    }

    func testHomebrewFormulaQueriesOnlyActualTokenBeforeAndAfterCommand() async throws {
        let recorder = AppUpdateFreshCallRecorder()
        var application = AppUpdateTestFixtures.strictHomebrewApplication(token: "example")
        application.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(kind: .formula, appBundlePaths: [])
        application.installationSource = .homebrewFormula
        application.caskToken = nil
        let provider = HomebrewProvider(
            applicationRechecker: AppUpdateFreshTestRechecker { _ in
                XCTFail("A formula must use its fresh CLI token, never a bundle display cache")
                return nil
            },
            installedFormulaVersionProvider: { token in
                recorder.record(token: token)
                return ApplicationVersion(marketing: recorder.commands == 0 ? "1.0" : "2.0", build: recorder.commands == 0 ? "100" : "")
            },
            homebrewExecutableProvider: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") },
            commandCapture: { _, _, _, _ in recorder.command(); return "updated" }
        )
        let prepared = try await provider.prepareUpdate(application)
        _ = try await provider.install(prepared) { _ in }
        XCTAssertEqual(recorder.tokens, ["example", "example"])
        XCTAssertEqual(recorder.commands, 1)
    }

    func testOfficialInstallerRevalidationReadsActualTargetAndRejectsSameVersionChildChange() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let inspector = AppUpdateCountingSignatureInspector()
        await inspector.requireUnchangedResource()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let display = makeDisplay(root: root, raw: raw)
        let cachedRead = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        let cached = try XCTUnwrap(cachedRead)
        let installer = OfficialApplicationUpdateInstaller(metadataReader: raw, runningStateProvider: { AppUpdatePerformanceTestSupport.idle })
        try await installer.revalidateInstalledApplication(cached)
        try Data("resource-b".utf8).write(to: url.appendingPathComponent("Contents/Resources/payload"))
        do {
            try await installer.revalidateInstalledApplication(cached)
            XCTFail("An earlier display signature cannot authorize the same-version changed target")
        } catch OfficialApplicationUpdateInstallerError.installedApplicationChanged { }
        let count = await raw.count
        let paths = await inspector.paths
        XCTAssertEqual(count, 3)
        XCTAssertEqual(paths, [url, url, url])
    }

    func testEveryExecutableProviderExecutorRechecksActualTargetBeforeAndAfter() async throws {
        for identifier: ApplicationUpdateProviderIdentifier in [.homebrew, .officialWebsite] {
            let root = try TestFileSystem.makeHome(for: self)
            let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
            let inspector = AppUpdateCountingSignatureInspector()
            let recorder = AppUpdateFreshCallRecorder()
            let application = automaticApplication(at: url, provider: identifier)
            let provider = FreshTargetTestProvider(identifier: identifier, recorder: recorder) {
                try AppUpdatePerformanceTestSupport.writeInfo(at: url, version: "2.0")
            }
            let executor = executor(provider: provider, inspector: inspector, root: root)
            let result = try await executor.execute(application: application, task: ApplicationUpdateTask(sessionID: UUID(), application: application), progress: { _ in })
            XCTAssertEqual(result.state, .completed, identifier.rawValue)
            let paths = await inspector.paths
            XCTAssertEqual(paths, identifier == .homebrew ? [url, url, url] : [url, url], "\(identifier): freeze package evidence, fresh preflight and fresh postflight")
            XCTAssertEqual(recorder.commands, 1)
        }
    }

    func testEveryExecutableProviderRejectsSameVersionChangeBeforeAndAfter() async throws {
        for identifier: ApplicationUpdateProviderIdentifier in [.homebrew, .officialWebsite] {
            for changedBefore in [true, false] {
                let root = try TestFileSystem.makeHome(for: self)
                let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
                let inspector = AppUpdateCountingSignatureInspector()
                await inspector.requireUnchangedResource()
                let recorder = AppUpdateFreshCallRecorder()
                let application = automaticApplication(at: url, provider: identifier)
                let mutate: @Sendable () throws -> Void = {
                    try Data("resource-b".utf8).write(to: url.appendingPathComponent("Contents/Resources/payload"))
                }
                let provider = FreshTargetTestProvider(identifier: identifier, recorder: recorder, operation: mutate)
                if changedBefore { try mutate() }
                do {
                    _ = try await executor(provider: provider, inspector: inspector, root: root).execute(application: application, task: ApplicationUpdateTask(sessionID: UUID(), application: application), progress: { _ in })
                    XCTFail("\(identifier) must reject changed actual code even at the same version")
                } catch ProviderBackedUpdateExecutorError.applicationIdentityChanged { }
                XCTAssertEqual(recorder.commands, changedBefore ? 0 : 1)
                let paths = await inspector.paths
                let expected = changedBefore ? [url] : [url, url]
                XCTAssertEqual(paths, identifier == .homebrew ? [url] + expected : expected)
            }
        }
    }

    func testHomebrewReconciliationDoesNotAcceptNewerDifferentArtifactAsActualTarget() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let other = try AppUpdatePerformanceTestSupport.bundle(in: root, name: "Duplicate", version: "2.0")
        var application = automaticApplication(at: url, provider: .homebrew)
        application.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(appBundlePaths: [other.path, url.path])
        let inspector = AppUpdateCountingSignatureInspector()
        let provider = FreshTargetTestProvider(identifier: .homebrew, recorder: AppUpdateFreshCallRecorder(), operation: {})
        do {
            _ = try await executor(provider: provider, inspector: inspector, root: root).reconcile(task: ApplicationUpdateTask(sessionID: UUID(), application: application), application: application)
            XCTFail("Updating a different copy is not completion for this actual target")
        } catch ProviderBackedUpdateExecutorError.applicationNoLongerEligible { }
        let paths = await inspector.paths
        XCTAssertTrue(paths.isEmpty, "Legacy GUI intent without the full original artifact list cannot reconcile from a shorter current scan")
    }

    func testNonInstallingProvidersRejectPreparedDisplayIdentityAndFreshExternalRecheckRejectsTampering() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let providers: [any ApplicationUpdateProvider] = [MacAppStoreProvider(masExecutableProvider: { nil }, outdatedProvider: { [:] }), SparkleProvider(automaticAdapter: nil), VendorUpdaterProvider(commandAdapter: .init(resolve: { _ in nil })), ManualUpdateProvider(), SystemManagedProvider()]
        for provider in providers {
            let inspector = AppUpdateCountingSignatureInspector()
            await inspector.requireUnchangedResource()
            let raw = AppUpdateCountingMetadataReader(inspector: inspector)
            let originalRead = await raw.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle, scanDate: Date())
            var original = try XCTUnwrap(originalRead)
            original.updateProvider = provider.identifier
            let prepared = PreparedApplicationUpdate(applicationID: original.id, providerIdentifier: provider.identifier, originalIdentity: original.identity, originalVersion: original.installedVersion, targetVersion: ApplicationVersion(marketing: "2.0"), providerPayload: [:])
            do { _ = try await provider.prepareUpdate(original); XCTFail("\(provider.identifier) must reject automatic preparation") }
            catch ApplicationScanningError.providerUnsupported { }
            do { _ = try await provider.install(prepared) { _ in }; XCTFail("\(provider.identifier) must reject automatic installation") }
            catch {
                switch provider.identifier {
                case .macAppStore:
                    XCTAssertEqual(error as? ProviderBackedUpdateExecutorError, .applicationNoLongerEligible)
                case .sparkle:
                    guard case SparkleAutomaticUpdateError.configurationChanged = error else { return XCTFail("Expected frozen Sparkle configuration rejection, got \(error)") }
                case .vendorUpdater:
                    XCTAssertEqual(error as? ProviderBackedUpdateExecutorError, .applicationIdentityChanged)
                case .manual, .systemManaged:
                    guard case let ApplicationScanningError.providerUnsupported(identifier) = error else { return XCTFail("Expected unsupported provider, got \(error)") }
                    XCTAssertEqual(identifier, provider.identifier.rawValue)
                default: XCTFail("Unexpected provider in non-installing fixture")
                }
            }
            try Data("resource-b".utf8).write(to: url.appendingPathComponent("Contents/Resources/payload"))
            let recorder = AppUpdateFreshCallRecorder()
            let verifier = ExternalUpdateVersionVerifier(rechecker: rechecker(raw: raw, recorder: recorder))
            let verified = try await verifier.verify(original)
            XCTAssertEqual(verified, .identityChanged)
            let count = await raw.count
            XCTAssertEqual(count, 2, "\(provider.identifier): original read plus mandatory fresh external read")
            XCTAssertEqual(recorder.paths, [url])
            try Data("resource-a".utf8).write(to: url.appendingPathComponent("Contents/Resources/payload"))
        }
    }

    private func makeDisplay(root: URL, raw: AppUpdateCountingMetadataReader) -> ApplicationInventoryMetadataReader {
        ApplicationInventoryMetadataReader(reader: raw, cache: ApplicationInventoryMetadataCache(fileURL: root.appendingPathComponent("display.json")), fingerprintReader: AppUpdatePerformanceTestSupport.fingerprints())
    }

    private func rechecker(raw: AppUpdateCountingMetadataReader, recorder: AppUpdateFreshCallRecorder) -> AppUpdateFreshTestRechecker {
        AppUpdateFreshTestRechecker { url in
            recorder.record(path: url)
            guard let application = await raw.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle, scanDate: Date()) else { return nil }
            return InstalledApplicationRecheckSnapshot(application: application, signature: AppUpdatePerformanceTestSupport.signature(for: application, valid: application.sourceEvidence.contains("valid-code-signature")))
        }
    }

    private func homebrew(raw: AppUpdateCountingMetadataReader, recorder: AppUpdateFreshCallRecorder, operation: @escaping @Sendable () throws -> Void) -> HomebrewProvider {
        HomebrewProvider(applicationRechecker: rechecker(raw: raw, recorder: recorder), homebrewExecutableProvider: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, commandCapture: { _, _, _, _ in recorder.command(); try operation(); return "updated" })
    }

    private func executor(provider: FreshTargetTestProvider, inspector: AppUpdateCountingSignatureInspector, root: URL) -> ProviderBackedApplicationUpdateExecutor {
        let reader = ApplicationMetadataReader(signatureInspector: inspector)
        let rechecker = AppUpdateFreshTestRechecker { url in
            guard let app = await reader.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle) else { return nil }
            return .init(application: app, signature: AppUpdatePerformanceTestSupport.signature(for: app, valid: app.sourceEvidence.contains("valid-code-signature")))
        }
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fixture/bin/brew") },
            command: FreshTargetReadOnlyPackageRunner(), rechecker: rechecker, captureExecutable: appUpdateFixtureExecutable)
        return ProviderBackedApplicationUpdateExecutor(processSafety: .init(processTable: { [] }), brewBatchInstaller: installer, providerRegistry: ApplicationUpdateProviderRegistry(providers: [provider]), metadataReader: reader, heavyWorkCoordinator: HeavyWorkCoordinator(), runningStateProvider: { AppUpdatePerformanceTestSupport.idle }, availableDiskCapacity: { _ in Int64.max }, replacementTransactionURL: root.appendingPathComponent("replacement.json"))
    }

    private func automaticApplication(at url: URL, provider: ApplicationUpdateProviderIdentifier) -> InstalledApplication {
        var application = AppUpdateTestFixtures.strictHomebrewApplication(path: url.path)
        if provider == .officialWebsite {
            application.updateProvider = provider
            application.homebrewMetadata = nil
            application.caskToken = nil
            application.officialSource = OfficialUpdateSource(
                applicationIdentity: application.identity, providerType: .officialWebsite,
                developerName: nil, homepageURL: URL(string: "https://example.com"),
                updatePageURL: URL(string: "https://example.com/download"), releaseFeedURL: nil,
                directDownloadURL: URL(string: "https://example.com/Example.dmg"), allowedHosts: ["example.com"],
                expectedBundleIdentifier: application.bundleIdentifier, expectedTeamIdentifier: application.signingTeamIdentifier,
                expectedDesignatedRequirement: nil, verificationMethod: .signedRegistry, trustLevel: .registryVerified,
                lastVerifiedAt: Date(), capability: .automatic, expectedPackageExtensions: ["dmg"], officialGitHubRepository: nil
            )
        }
        return application
    }
}

private struct FreshTargetReadOnlyPackageRunner: HomebrewCommandRunning {
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        XCTAssertEqual(arguments.first, "list", "No real or injected installation is allowed from recovery")
        return Data("example 2.0\n".utf8)
    }
}

private struct FreshTargetTestProvider: ApplicationUpdateProvider {
    let identifier: ApplicationUpdateProviderIdentifier
    let recorder: AppUpdateFreshCallRecorder
    let operation: @Sendable () throws -> Void
    func canHandle(_ application: InstalledApplication) async -> Bool { application.updateProvider == identifier }
    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        ApplicationUpdateSourceInfo(providerIdentifier: identifier, evidence: [], requiresUserInteraction: false, canAutomaticallyUpdate: true)
    }
    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult { throw ApplicationScanningError.providerUnsupported(identifier.rawValue) }
    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        PreparedApplicationUpdate(applicationID: application.id, providerIdentifier: identifier, originalIdentity: application.identity, originalVersion: application.installedVersion, targetVersion: application.availableVersion, providerPayload: [:])
    }
    func install(_ preparedUpdate: PreparedApplicationUpdate, progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void) async throws -> ApplicationUpdateInstallResult {
        recorder.command()
        try operation()
        return ApplicationUpdateInstallResult(applicationID: preparedUpdate.applicationID, state: .needsReconciliation, observedVersion: nil, detail: "Fixture command completed")
    }
}
