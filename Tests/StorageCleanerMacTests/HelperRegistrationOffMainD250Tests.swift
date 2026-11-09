import XCTest
@testable import StorageCleanerMac

/// D250 (G batch, install22 13:21): ServiceManagement checks this app's
/// signature on the calling thread for each `register()`; on the main thread
/// every call reported two Security “should not be called on the main
/// thread” faults. Both helpers now register and unregister off the main
/// thread, on a service object made there.
final class HelperRegistrationOffMainD250Tests: XCTestCase {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every `.register()` and `.unregister()` in `code` sits in `helpers`.
    private func assertCallsOnlyIn(_ helpers: String, of code: String, file: StaticString = #filePath, line: UInt = #line) {
        for call in [".register()", ".unregister()"] {
            XCTAssertEqual(code.components(separatedBy: call).count, helpers.components(separatedBy: call).count,
                           "\(call) outside the off-main helper", file: file, line: line)
        }
    }

    func testFileOperationHelperRegistersInADetachedTask() throws {
        let mover = try source("Sources/StorageCleanerMac/Services/AuthorizedApplicationMover.swift")
        let prepare = SwiftSourceScanning.code(try r2SourceDeclaration(
            "func prepareHelper(forceRefresh: Bool = false, refreshRegisteredBuild: Bool = true) async throws", in: mover))
        XCTAssertTrue(prepare.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(prepare.contains("Self.registerHelper(refreshing: refresh, registeredBuildKey: key)"))
        XCTAssertTrue(prepare.contains("withTaskCancellationHandler"), "cancelling the caller cancels the registration")
        XCTAssertFalse(prepare.contains("service.status"), "the status is read off the main actor too")
        let register = SwiftSourceScanning.code(try r2SourceDeclaration(
            "nonisolated private static func registerHelper(refreshing: Bool, registeredBuildKey key: String) async throws -> SMAppService.Status",
            in: mover))
        // `code(_:)` blanks literal contents: the plist suffix is checked up to the `+`.
        XCTAssertTrue(register.contains("SMAppService.daemon(plistName: FileOperationIdentity.helper +"))
        XCTAssertTrue(register.contains("try await service.unregister()"))
        XCTAssertTrue(register.contains("try service.register()"))
        XCTAssertTrue(register.contains("failure.code == 1"), "the observed BTM race still retries once")
        let code = SwiftSourceScanning.code(mover)
        XCTAssertFalse(code.contains("private let service = SMAppService"),
                       "no main-actor service object is left to call by mistake")
        assertCallsOnlyIn(register, of: code)
    }

    func testFanHelperRegistersAndUnregistersOffTheMainThread() throws {
        let coordinator = try source("Sources/StorageCleanerMac/Services/FanControlCoordinator.swift")
        let register = SwiftSourceScanning.code(try r2SourceDeclaration("private func registerService() async throws", in: coordinator))
        XCTAssertTrue(register.contains("try await Self.registerDaemonOffMain(plistName: Self.helperPlistName)"))
        let code = SwiftSourceScanning.code(coordinator)
        XCTAssertTrue(code.contains("try await Self.unregisterDaemonOffMain(plistName: Self.helperPlistName)"))
        var helpers = ""
        for name in ["nonisolated static func registerDaemonOffMain(plistName: String) async throws",
                     "nonisolated static func unregisterDaemonOffMain(plistName: String) async throws"] {
            let body = SwiftSourceScanning.code(try r2SourceDeclaration(name, in: coordinator))
            XCTAssertTrue(body.contains("Task.detached(priority: .userInitiated)"), name)
            XCTAssertTrue(body.contains("SMAppService.daemon(plistName: plistName)"), name)
            helpers += body
        }
        assertCallsOnlyIn(helpers, of: code)
    }
}
