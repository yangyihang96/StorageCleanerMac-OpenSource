import Combine
import Foundation
import XCTest
@testable import StorageCleanerMac

private func isOnMainThread() -> Bool {
    Thread.isMainThread
}

/// 2026-10-06, Beta 20261005020648: confirming "Move to Trash" crashed right
/// after the receipt was saved. `CleanReportStore.recordDetached` writes the
/// legacy receipt cache off the main thread, UserDefaults posts
/// `didChangeNotification` synchronously on that thread, and the status item's
/// sink inherited main-actor isolation from `install`, so Swift 6's runtime
/// isolation check trapped (EXC_BREAKPOINT). With that sink shape the two
/// runtime tests below end the test process with the same trap.
final class MenuBarDefaultsChangeSubscriptionTests: XCTestCase {
    @MainActor
    func testDefaultsNotificationOnWorkerThreadSchedulesStatusRefreshOnMainActor() async {
        let center = NotificationCenter()
        let refreshed = expectation(description: "status item refresh runs on the main actor")
        let subscription = MenuBarStatusController.defaultsChangeSubscription(center: center) {
            XCTAssertTrue(Thread.isMainThread)
            refreshed.fulfill()
        }

        let postedOffMainThread = await Task.detached(priority: .utility) {
            let onMainThread = isOnMainThread()
            center.post(name: UserDefaults.didChangeNotification, object: nil)
            return !onMainThread
        }.value

        XCTAssertTrue(postedOffMainThread)
        await fulfillment(of: [refreshed], timeout: 5)
        withExtendedLifetime(subscription) {}
    }

    /// The crash path itself: a receipt saved off the main thread writes the
    /// legacy cache and UserDefaults notifies through the default center on
    /// that thread. Only an isolated defaults suite is written.
    @MainActor
    func testReceiptSavedOffMainThreadDoesNotTrapStatusItemSubscription() async throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        addTeardownBlock { TestPreferenceDomain.cleanup(suiteName: suite) }
        let refreshed = expectation(description: "status item refresh scheduled after the receipt save")
        refreshed.assertForOverFulfill = false
        let subscription = MenuBarStatusController.defaultsChangeSubscription {
            refreshed.fulfill()
        }
        let report = Self.movedReceiptReport()

        let saved = await Task.detached(priority: .utility) {
            guard let workerDefaults = TestPreferenceDomain.open(suiteName: suite) else { return false }
            return CleanReportStore.record(report, defaults: workerDefaults)
        }.value

        XCTAssertTrue(saved)
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(CleanReportStore.load(defaults: defaults).map(\.planID), [report.planID])
        withExtendedLifetime(subscription) {}
    }

    /// Any defaults write may notify on a worker thread. A Combine or SwiftUI
    /// handler written in a main-actor context inherits that isolation unless
    /// it is `@Sendable`, so each subscription must either hop to the main
    /// queue before its first closure or mark its sink closure `@Sendable`.
    /// Observer blocks run on the posting thread unless given the main queue,
    /// so they must not assume main-actor isolation.
    func testDefaultsChangeSubscriptionsDoNotInheritMainActorIsolation() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = projectRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL]
        ).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100)

        let publisherPattern = try NSRegularExpression(
            pattern: #"publisher\(\s*for:\s*UserDefaults\.didChangeNotification"#
        )
        let observerPattern = try NSRegularExpression(
            pattern: #"addObserver\(\s*forName:\s*UserDefaults\.didChangeNotification"#
        )
        var publisherCount = 0
        var observerCount = 0
        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let text = source as NSString
            let everything = NSRange(location: 0, length: text.length)
            func location(_ match: NSTextCheckingResult) -> String {
                let line = text.substring(to: match.range.location).components(separatedBy: "\n").count
                return "\(file.path.replacingOccurrences(of: projectRoot.path + "/", with: "")):\(line)"
            }

            for match in publisherPattern.matches(in: source, range: everything) {
                publisherCount += 1
                let rest = text.substring(from: NSMaxRange(match.range))
                guard let brace = rest.firstIndex(of: "{") else {
                    violations.append(location(match))
                    continue
                }
                let chain = rest[..<brace]
                let handler = rest[rest.index(after: brace)...].drop { $0.isWhitespace }
                let hopsToMainQueue = chain.contains(".receive(on:")
                let sendableSink = chain.contains(".sink") && handler.hasPrefix("@Sendable")
                if !hopsToMainQueue && !sendableSink {
                    violations.append(location(match))
                }
            }

            for match in observerPattern.matches(in: source, range: everything) {
                observerCount += 1
                let call = Self.callText(in: text, from: match.range.location)
                if !call.contains("queue: .main") && call.contains("assumeIsolated") {
                    violations.append(location(match))
                }
            }
        }

        // The status item, the auxiliary monitor and the L10n cache.
        XCTAssertGreaterThanOrEqual(publisherCount, 2)
        XCTAssertGreaterThanOrEqual(observerCount, 1)
        XCTAssertEqual(
            violations,
            [],
            "A UserDefaults change handler must hop to the main queue with .receive(on:) before its first closure, or mark its sink closure @Sendable"
        )
    }

    /// The call starting at `start`: its balanced argument list and a
    /// trailing closure when one follows.
    private static func callText(in text: NSString, from start: Int) -> String {
        let characters = Array(text.substring(from: start).utf16)
        let open = UInt16(UInt8(ascii: "(")), close = UInt16(UInt8(ascii: ")"))
        let openBrace = UInt16(UInt8(ascii: "{")), closeBrace = UInt16(UInt8(ascii: "}"))
        func balancedEnd(from index: Int, opening: UInt16, closing: UInt16) -> Int? {
            var depth = 0
            var position = index
            while position < characters.count {
                if characters[position] == opening { depth += 1 }
                if characters[position] == closing {
                    depth -= 1
                    if depth == 0 { return position }
                }
                position += 1
            }
            return nil
        }
        guard let firstParen = characters.firstIndex(of: open),
              var end = balancedEnd(from: firstParen, opening: open, closing: close) else {
            return text.substring(from: start)
        }
        var next = end + 1
        while next < characters.count, Character(UnicodeScalar(characters[next]) ?? " ").isWhitespace {
            next += 1
        }
        if next < characters.count, characters[next] == openBrace,
           let closureEnd = balancedEnd(from: next, opening: openBrace, closing: closeBrace) {
            end = closureEnd
        }
        return String(decoding: characters[...end], as: UTF16.self)
    }

    private static func movedReceiptReport() -> CleanReport {
        let receipt = CleanupMoveReceipt(
            originalPath: "/Users/fixture/Library/Caches/menu-bar-defaults",
            resultingItemURL: URL(fileURLWithPath: "/Users/fixture/.Trash/menu-bar-defaults"),
            disposition: .trash,
            movedIdentity: FileIdentity(deviceID: 1, inode: 2, entryKind: .regularFile, creationTimeNanoseconds: 3),
            verification: .identityVerified,
            movedAt: Date()
        )
        let item = CleanReportItem(
            id: UUID(),
            planItemID: UUID(),
            ruleID: "fixture.rule",
            sourcePath: receipt.originalPath,
            estimatedBytes: 1_024,
            outcome: .moved(receipt)
        )
        return CleanReport(
            id: UUID(),
            planID: CleanPlanID(),
            sessionID: ScanSessionID(),
            rulesVersion: "fixture-rules",
            disposition: .trash,
            scanWasPartial: false,
            startedAt: Date(),
            completedAt: Date(),
            outcome: .completed,
            items: [item],
            summary: CleanReportSummary(
                requestedItemCount: 1,
                movedItemCount: 1,
                skippedItemCount: 0,
                failedItemCount: 0,
                notProcessedItemCount: 0,
                unverifiedMoveCount: 0,
                plannedBytes: 1_024,
                movedToRecoverableLocationBytes: 1_024,
                reclaimableAfterEmptyingTrashBytes: nil,
                permanentlyFreedBytes: 0,
                availableSpaceDeltaBytes: nil
            )
        )
    }
}
