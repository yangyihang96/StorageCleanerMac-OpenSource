import XCTest

/// D192 hotfix (10-24): the tenth test beta crashed in a junk scan. XPC runs
/// a proxy's error handler on its own queue; a closure written in a
/// main-actor type without `@Sendable` inherits that isolation, and the Swift
/// runtime check traps there as soon as the helper connection fails
/// (`SystemCacheService.exchange`, EXC_BREAKPOINT in
/// `swift_task_isCurrentExecutor`).
final class XPCCallbackIsolationTests: XCTestCase {
    func testEveryProxyErrorHandlerIsSendable() throws {
        let sources = SwiftSourceScanning.projectRoot.appendingPathComponent("Sources/StorageCleanerMac")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var handlers = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains("remoteObjectProxyWithErrorHandler") {
                handlers += 1
                if !line.contains("@Sendable") {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(handlers, 4, "the helper clients were not found")
        XCTAssertEqual(offenders, [])
    }

    func testTheMainActorHelperExchangesKeepTheirRepliesOffTheMainActor() throws {
        for file in ["Services/SystemCacheService.swift",
                     "Services/AuthorizedApplicationMover.swift",
                     "Services/AppUpdateProtectedApplicationAuthorization.swift"] {
            let source = try String(contentsOf: SwiftSourceScanning.projectRoot
                .appendingPathComponent("Sources/StorageCleanerMac").appendingPathComponent(file), encoding: .utf8)
            for line in source.components(separatedBy: .newlines)
            where line.contains("invalidationHandler = {") || line.contains("interruptionHandler = {") {
                XCTAssertTrue(line.contains("@Sendable"), "\(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        let mover = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Services/AuthorizedApplicationMover.swift"), encoding: .utf8)
        XCTAssertTrue(mover.contains("proxy.commit(data) { @Sendable reply in"))
        XCTAssertTrue(mover.contains("proxy.prepare(data, authorization: authorization) { @Sendable reply in"))
        let updates = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Services/AppUpdateProtectedApplicationAuthorization.swift"), encoding: .utf8)
        XCTAssertTrue(updates.contains("@escaping @Sendable (Data) -> Void) -> Void) async throws -> Data"))
    }
}
