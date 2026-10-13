import Foundation
import XCTest
@testable import StorageCleanerMac

final class VendorAutomaticUpdateTests: XCTestCase {
    func testVerifiedMicrosoftCommandChecksThenInstallsOnlyFrozenProduct() async throws {
        let recorder = VendorTestRecorder()
        let command = VendorUpdateCommand(kind: .microsoft, executableURL: URL(fileURLWithPath: "/fake/msupdate"), productID: "MSWD2019")
        var app = AppUpdateTestFixtures.application(id: "vendor", bundleIdentifier: "com.microsoft.Word", version: "1.0", provider: .vendorUpdater,
            sourceEvidence: ["valid-code-signature", "signed-bundle-identity"], canAutomaticallyUpdate: true, requiresUserInteraction: false)
        let original = app
        let adapter = VendorCommandUpdateAdapter(resolve: { _ in command }, run: { url, args in
            XCTAssertEqual(url, command.executableURL)
            await recorder.record(args)
            if args.first == "--list" {
                return try PropertyListSerialization.data(fromPropertyList: ["Updates": [["ApplicationID": "MSWD2019", "Version": "2.0"]]], format: .xml, options: 0)
            }
            return Data()
        })
        let provider = VendorUpdaterProvider(commandAdapter: adapter, readApplication: { _ in original })
        app = await ApplicationUpdateProviderRegistry(providers: [provider]).classify(app)
        XCTAssertTrue(app.canJoinAutomaticUpdateBatch)
        XCTAssertEqual(app.availableVersion, .init(marketing: "2.0"))
        let prepared = try await provider.prepareUpdate(app)
        let result = try await provider.install(prepared) { _ in }
        XCTAssertEqual(result.state, .needsReconciliation)
        let calls = await recorder.calls
        XCTAssertEqual(calls, [["--list", "--format", "plist"], ["--install", "--apps", "MSWD2019", "--wait", "1800"]])
    }

    func testVerifiedGoogleCommandCanCheckAndUpdateWithoutInventingTargetVersion() async {
        let command = VendorUpdateCommand(kind: .google, executableURL: URL(fileURLWithPath: "/fake/ksadmin"), productID: "com.google.Chrome")
        let provider = VendorUpdaterProvider(commandAdapter: .init(resolve: { _ in command }, run: { _, _ in XCTFail("Google scan must not install"); return Data() }))
        let app = await ApplicationUpdateProviderRegistry(providers: [provider]).classify(AppUpdateTestFixtures.application(
            id: "google", bundleIdentifier: "com.google.Chrome", provider: .vendorUpdater, sourceEvidence: ["valid-code-signature"], requiresUserInteraction: false))
        XCTAssertNil(app.availableVersion)
        XCTAssertTrue(app.canJoinAutomaticUpdateBatch)
        XCTAssertEqual(AppUpdateBatchPresentation(applications: [app]).count, 1)
        XCTAssertEqual(command.installArguments, ["--update", "--productid", "com.google.Chrome"])
    }

    func testChangedOfficialCommandRejectsBeforeInstallation() async throws {
        let original = AppUpdateTestFixtures.application(provider: .vendorUpdater)
        let command = VendorUpdateCommand(kind: .microsoft, executableURL: URL(fileURLWithPath: "/fake/msupdate"), productID: "MSWD2019")
        let provider = VendorUpdaterProvider(commandAdapter: .init(resolve: { _ in command }, run: { _, _ in XCTFail("Tampered command must not execute"); return Data() }),
            readApplication: { _ in original })
        let prepared = try await provider.prepareUpdate(original)
        var payload = prepared.providerPayload
        payload["command-path"] = "/bin/sh"
        let tampered = PreparedApplicationUpdate(applicationID: prepared.applicationID, providerIdentifier: prepared.providerIdentifier,
            originalIdentity: prepared.originalIdentity, originalVersion: prepared.originalVersion, targetVersion: prepared.targetVersion, providerPayload: payload)
        do { _ = try await provider.install(tampered) { _ in }; XCTFail("Reject changed command") }
        catch ProviderBackedUpdateExecutorError.applicationIdentityChanged {}
    }

    func testUnknownVendorTargetRequiresNewerActualVersionAndRejectsDowngrade() async throws {
        for version in ["0.9", "1.0", "2.0"] {
            let root = try TestFileSystem.makeHome(for: self)
            let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
            let reader = ApplicationMetadataReader(signatureInspector: AppUpdateCountingSignatureInspector())
            let read = await reader.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
            var original = try XCTUnwrap(read)
            original.updateProvider = .vendorUpdater
            original.availableVersion = nil
            let task = ApplicationUpdateTask(sessionID: UUID(), application: original)
            try AppUpdatePerformanceTestSupport.writeInfo(at: url, version: version)
            let executor = ProviderBackedApplicationUpdateExecutor(processSafety: .init(processTable: { [] }), metadataReader: reader,
                heavyWorkCoordinator: HeavyWorkCoordinator(), runningStateProvider: { AppUpdatePerformanceTestSupport.idle })
            do {
                let result = try await executor.reconcile(task: task, application: original)
                XCTAssertEqual(version, "2.0", "An unchanged or lower actual version cannot complete an update")
                XCTAssertEqual(result.state, .completed)
                XCTAssertEqual(result.observedVersion?.marketing, "2.0")
            } catch ProviderBackedUpdateExecutorError.versionDidNotChange {
                XCTAssertNotEqual(version, "2.0", "The higher actual version should complete")
            }
        }
    }
}
private actor VendorTestRecorder { var calls = [[String]](); func record(_ args: [String]) { calls.append(args) } }
