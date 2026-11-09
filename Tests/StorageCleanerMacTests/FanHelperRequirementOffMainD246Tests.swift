@testable import FanControlShared
import Foundation
import XCTest

/// D246: the app's requirement for the fan-control helper is made off the main
/// thread, once. Reading the app's signing certificates evaluates their trust,
/// and Security reports that when it runs on the main thread ("This method
/// should not be called on the main thread as it may lead to UI
/// unresponsiveness", two reports per call). helperConnection() made it on the
/// main actor for every new connection: install22 logged four at launch, one
/// pair right before each of the two connections (12:44:25.482, 12:44:27.355).
final class FanHelperRequirementOffMainD246Tests: XCTestCase {
    private static func coordinatorSource() throws -> String {
        SwiftSourceScanning.code(try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"), encoding: .utf8))
    }

    /// Made on a detached utility task, awaited in the signing preflight before
    /// trust is recorded; performSend connects only once trust is recorded.
    func testTheCoordinatorMakesTheRequirementOffTheMainThreadBeforeConnecting() throws {
        let source = try Self.coordinatorSource()
        let compact = SwiftSourceScanning.compact(source)
        XCTAssertTrue(compact.contains("privatestaticlethelperRequirementTask:Task<Void,Never>={letlabel=helperLabel"
            + "returnTask.detached(priority:.utility){_=FanControlPeerRequirement.currentSigner(peerIdentifier:label)}}()"))

        let resolve = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "private func resolveBundledHelperSigningTrust() async -> Bool", in: source))
        let started = try XCTUnwrap(resolve.range(of: "letrequirement=Self.helperRequirementTask"), resolve)
        let made = try XCTUnwrap(resolve.range(of: "awaitrequirement.value"), resolve)
        let recorded = try XCTUnwrap(resolve.range(of: "bundledHelperSigningIsTrusted=trusted"), resolve)
        XCTAssertLessThanOrEqual(started.upperBound, made.lowerBound, resolve)
        XCTAssertLessThanOrEqual(made.upperBound, recorded.lowerBound, resolve)

        let perform = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "private func performSend(_ request: FanControlHelperRequest,", in: source))
        let trusted = try XCTUnwrap(perform.range(
            of: "guardbundledHelperSigningIsTrusted==trueelse{throwFanControlConnectionError.untrustedBundledHelper}"), perform)
        let connected = try XCTUnwrap(perform.range(of: "tryhelperConnection()"), perform)
        XCTAssertLessThan(trusted.upperBound, connected.lowerBound, perform)

        // The task and the connection, which reads the kept requirement.
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "FanControlPeerRequirement.currentSigner(", in: compact), 2)
    }

    /// The first requirement made from this process's signature is kept, as
    /// the helper keeps the one it made at startup.
    func testCurrentSignerReturnsTheKeptRequirement() throws {
        let source = SwiftSourceScanning.code(try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/FanControlShared/FanControlPeerRequirement.swift"), encoding: .utf8))
        let current = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "public static func currentSigner(peerIdentifier: String) -> String?", in: source))
        XCTAssertEqual(current, "guardpeerIdentifier==StorageCleanerBuildIdentity.helperLabelelse{returnnil}"
            + "returnstartupSigner.value{signerRequirement(peerIdentifier:peerIdentifier)}")
    }

    /// Kept once made, so a later connection does not read the certificates
    /// again; nil (ad hoc or unsigned: no certificates, nothing to evaluate) is
    /// made again when asked.
    func testTheFirstRequirementMadeIsKeptAndNilIsNot() {
        let kept = StartupSignerRequirement()
        var made = 0
        XCTAssertNil(kept.value { made += 1; return nil })
        XCTAssertNil(kept.value { made += 1; return nil })
        XCTAssertEqual(made, 2)
        XCTAssertEqual(kept.value { made += 1; return "first" }, "first")
        XCTAssertEqual(kept.value { made += 1; return "second" }, "first")
        XCTAssertEqual(kept.value { made += 1; return nil }, "first")
        XCTAssertEqual(made, 3)
    }

    /// Callers racing the first one all get the same kept text.
    func testConcurrentCallersGetOneRequirement() async {
        let kept = StartupSignerRequirement()
        let values = await withTaskGroup(of: String?.self) { group in
            for index in 0..<32 {
                group.addTask { kept.value { "requirement \(index)" } }
            }
            var values: [String?] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values.count, 32)
        XCTAssertEqual(Set(values.compactMap { $0 }).count, 1, "\(values)")
        XCTAssertFalse(values.contains(nil))
    }
}
