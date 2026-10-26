import Foundation
import XCTest
@testable import StorageCleanerMac

/// D98 ⑤: cleanup removes user items by moving them to the Trash. Permanent
/// deletion is reached only through Empty Trash: the D23 smart-scan item and,
/// since D101 L5, the legacy menu command. Both delete only frozen entries
/// through the one deleter after two confirmations. Since D101 G2, simulator
/// devices and runtimes are deleted only by simctl's own commands, also after
/// two confirmations. Scope: files that move items to the Trash; a full
/// inventory of deletion calls is BOARD L8.
final class PermanentDeletionInvariantTests: XCTestCase {
    private static let executor = "Sources/StorageCleanerMac/Services/SafeCleanupExecutor.swift"
    private static let cleanupService = "Sources/StorageCleanerMac/Services/CleanupService.swift"
    private static let heavyWork = "Sources/StorageCleanerMac/Services/ScanHeavyWorkService.swift"
    private static let scanStore = "Sources/StorageCleanerMac/Stores/ScanStore.swift"
    private static let reminders = "Sources/StorageCleanerMac/Features/AppLifecycle/Reminders/AppLifecycleReminderCenter.swift"
    private static let deletionCall = try! NSRegularExpression(
        pattern: #"\b(?:removeItem|unlinkat|unlink|rmdir|removefile)\s*\(|\bDarwin\s*\.\s*remove\s*\("#)
    private static let trashMove = try! NSRegularExpression(pattern: #"\btrashItem\s*\("#)

    func testOnlyTheEmptyTrashActionDeletesPermanently() {
        // A new action does not compile here until it is classified.
        func deletesPermanently(_ action: CleanupRuleAction) -> Bool {
            switch action {
            case .emptyTrash: true
            case .moveToTrash, .moveToTrashAfterReview, .moveToTrashAfterProtectedReview, .revealOnly: false
            }
        }
        let actions: [CleanupRuleAction] = [.moveToTrash, .moveToTrashAfterReview, .moveToTrashAfterProtectedReview,
                                            .revealOnly, .emptyTrash]
        for action in actions {
            XCTAssertEqual(action.permanentlyDeletes, deletesPermanently(action), action.rawValue)
            XCTAssertFalse(action.permanentlyDeletes && action.movesToTrash, action.rawValue)
        }
    }

    /// A file that moves items to the Trash deletes nothing, except inside
    /// the one Empty Trash deleter (matched by braces).
    func testFilesThatMoveItemsToTheTrashDeleteOnlyInsideEmptyTrash() throws {
        let movers = try SwiftSourceScanning.sourceCode().filter { Self.count(Self.trashMove, in: $0.value) > 0 }
        // The scan must see the known Trash movers, or it proves nothing.
        for known in [Self.cleanupService, Self.executor,
                      "Sources/StorageCleanerMac/Services/RecordedTrashOperation.swift",
                      "Sources/StorageCleanerMac/Services/AppUninstallService.swift",
                      "Sources/StorageCleanerMac/Features/LargeFiles/Services/FileAnalysisTrashService.swift"] {
            XCTAssertNotNil(movers[known], known)
        }
        let emptyTrash = [Self.executor: "struct FoundationCleanupPermanentDeleter"]
        for (path, code) in movers.sorted(by: { $0.key < $1.key }) {
            let total = Self.count(Self.deletionCall, in: code)
            guard let declaration = emptyTrash[path] else {
                XCTAssertEqual(total, 0, "\(path) moves items to the Trash and must not delete them")
                continue
            }
            let implementation = try SwiftSourceScanning.body(of: declaration, in: code)
            XCTAssertGreaterThan(Self.count(Self.deletionCall, in: implementation), 0, path)
            XCTAssertEqual(total, Self.count(Self.deletionCall, in: implementation),
                           "\(path) deletes outside its Empty Trash implementation")
        }
    }

    /// The one deleter is built only as the default of its two flows, and
    /// each flow calls it behind its own gate.
    func testPermanentDeletionIsReachableOnlyFromTheEmptyTrashFlows() throws {
        let code = try SwiftSourceScanning.sourceCode()
        let compact = try SwiftSourceScanning.compactSourceCode()
        func files(containing needle: String) -> [String] {
            compact.filter { $0.value.contains(needle) }.keys.sorted()
        }
        XCTAssertEqual(files(containing: ".removeTrashEntry("), [Self.cleanupService, Self.executor])
        XCTAssertEqual(files(containing: "FoundationCleanupPermanentDeleter()"), [Self.executor, Self.heavyWork])
        XCTAssertEqual(files(containing: "FoundationCleanupPermanentDeleter"), [Self.cleanupService, Self.executor, Self.heavyWork])
        XCTAssertEqual(files(containing: "emptyUserTrash"), [])
        XCTAssertEqual(files(containing: ".emptyFrozenTrash("), [Self.heavyWork])
        XCTAssertEqual(files(containing: ".emptyTrash(frozen,lease:"), [Self.reminders, Self.scanStore])
        XCTAssertEqual(Self.permanentDeleters(in: code), ["FoundationCleanupPermanentDeleter"])

        // D23 smart-scan item: the executor's one deleter, only for an action that deletes.
        let executor = try XCTUnwrap(code[Self.executor])
        let flatExecutor = try XCTUnwrap(compact[Self.executor])
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "FoundationCleanupPermanentDeleter", in: flatExecutor), 2)
        XCTAssertTrue(flatExecutor.contains("deleter:anyCleanupPermanentDeleting=FoundationCleanupPermanentDeleter()"))
        let deleter = try SwiftSourceScanning.body(of: "struct FoundationCleanupPermanentDeleter", in: executor)
        XCTAssertEqual(SwiftSourceScanning.compact(try SwiftSourceScanning.body(of: "func removeTrashEntry(", in: deleter)),
                       "trySelf.remove(deletion)")
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "Self.remove(", in: flatExecutor), 1)
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: ".removeTrashEntry(", in: flatExecutor), 1)
        let frozen = try SwiftSourceScanning.body(of: "private func deleteFrozenTrashEntry(", in: executor)
        XCTAssertTrue(SwiftSourceScanning.compact(frozen).contains("deleter.removeTrashEntry("))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "deleteFrozenTrashEntry(item", in: flatExecutor), 1)
        let dispatch = try SwiftSourceScanning.body(of: "if item.action.permanentlyDeletes {", in: executor)
        XCTAssertTrue(SwiftSourceScanning.compact(dispatch).contains("deleteFrozenTrashEntry(item"))

        // Legacy menu command (D101 L5): the list frozen for the confirmation,
        // run only with both confirmations, entry by entry through the deleter.
        let store = try XCTUnwrap(code[Self.scanStore])
        let confirm = SwiftSourceScanning.compact(try SwiftSourceScanning.body(of: "func confirmEmptyTrash(", in: store))
        XCTAssertTrue(confirm.hasPrefix(
            "guardletfrozen=pendingEmptyTrash,acknowledgesPermanentDeletion,acknowledgesTrashContentsReviewed,canRequestEmptyTrashelse{return}"
        ), confirm)
        XCTAssertTrue(confirm.contains("service.emptyTrash(frozen,lease:lease)"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: ".emptyTrash(", in: try XCTUnwrap(compact[Self.scanStore])), 1)
        // The Trash-size reminder's Empty Trash (CleanMyMac `TrashSize_Issue`,
        // handoffs/app-lifecycle-cmm.md): the same frozen list and both
        // acknowledgements, through the heavy-work service's one entry point.
        let reminders = try XCTUnwrap(code[Self.reminders])
        let reminderConfirm = SwiftSourceScanning.compact(try SwiftSourceScanning.body(of: "func confirmEmptyTrash(", in: reminders))
        XCTAssertTrue(reminderConfirm.hasPrefix(
            "guardcase.confirming(letfrozen)=emptyTrashPhase,acknowledgesPermanentDeletion,acknowledgesTrashContentsReviewed,letheavyWorkelse{return}"
        ), reminderConfirm)
        XCTAssertTrue(reminderConfirm.contains("heavyWork.emptyTrash(frozen,lease:lease)"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: ".emptyTrash(", in: try XCTUnwrap(compact[Self.reminders])), 1)
        let reminderFreeze = SwiftSourceScanning.compact(try SwiftSourceScanning.body(of: "func requestEmptyTrash(", in: reminders))
        XCTAssertTrue(reminderFreeze.contains("heavyWork.freezeTrash()"))
        XCTAssertTrue(reminderFreeze.contains("emptyTrashPhase=.confirming(frozen)"))
        let flatHeavyWork = try XCTUnwrap(compact[Self.heavyWork])
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "FoundationCleanupPermanentDeleter", in: flatHeavyWork), 1)
        XCTAssertTrue(flatHeavyWork.contains("awaitCleanupService.emptyFrozenTrash(frozen,deleter:FoundationCleanupPermanentDeleter())"))
        let service = try XCTUnwrap(code[Self.cleanupService])
        let emptyFrozen = SwiftSourceScanning.compact(try SwiftSourceScanning.body(of: "static func emptyFrozenTrash(", in: service))
        XCTAssertTrue(emptyFrozen.contains(
            "deleter.removeTrashEntry(CleanupTrashEntryDeletion(trashURL:frozen.trashURL,trashIdentity:frozen.trashIdentity,entryName:entry.name,entryIdentity:entry.identity))"
        ), emptyFrozen)
        // The service only reads identities with the deleter's own reader.
        let flatService = try XCTUnwrap(compact[Self.cleanupService])
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "FoundationCleanupPermanentDeleter", in: flatService),
                       SwiftSourceScanning.occurrences(of: "FoundationCleanupPermanentDeleter.identity(at:", in: flatService))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: ".removeTrashEntry(", in: flatService), 1)
    }

    /// D101 G2: only the simulator service names simctl and builds its delete
    /// commands, one identifier each; only the controller's confirmation runs
    /// them, behind both acknowledgments and the list frozen for it.
    func testSimulatorItemsAreDeletedOnlyBySimctlAfterTwoConfirmations() throws {
        let service = "Sources/StorageCleanerMac/Services/SimulatorCleanupService.swift"
        let controller = "Sources/StorageCleanerMac/Views/SimulatorCleanupView.swift"
        let literals = try SwiftSourceScanning.sources().mapValues(SwiftSourceScanning.compactKeepingLiterals)
        let compact = try SwiftSourceScanning.compactSourceCode()
        func files(_ text: [String: String], containing needle: String) -> [String] {
            text.filter { $0.value.contains(needle) }.keys.sorted()
        }
        XCTAssertEqual(files(literals, containing: "\"simctl\""), [service])
        XCTAssertEqual(files(literals, containing: "\"delete\""), [service])
        let serviceText = try XCTUnwrap(literals[service])
        for word in ["\"all\"", "\"unavailable\"", "\"booted\""] {
            XCTAssertFalse(serviceText.contains(word), word)
        }
        let arguments = SwiftSourceScanning.compactKeepingLiterals(
            try SwiftSourceScanning.body(of: "var deletionArguments: [String]", in: try XCTUnwrap(SwiftSourceScanning.sources()[service])))
        XCTAssertEqual(arguments, #"switchkind{case.unavailableDevice:["delete",identifier]case.unusedRuntime:["runtime","delete",identifier]}"#)
        XCTAssertEqual(files(compact, containing: ".deletionArguments"), [service])
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: ".deletionArguments", in: try XCTUnwrap(compact[service])), 1)
        let delete = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "func delete(_ frozen: [SimulatorCleanupItem])", in: try XCTUnwrap(SwiftSourceScanning.sourceCode()[service])))
        XCTAssertTrue(delete.hasPrefix("varresult=SimulatorCleanupResult()guardawaitrunningOwners().isEmptyelse{"), delete)
        XCTAssertTrue(delete.contains("guardeligible.contains(item.target),SimulatorCleanupPolicy.isSingleItemIdentifier(item.identifier)else{"))

        XCTAssertEqual(files(compact, containing: "service.delete("), [controller])
        let code = try XCTUnwrap(SwiftSourceScanning.sourceCode()[controller])
        let confirm = SwiftSourceScanning.compact(try SwiftSourceScanning.body(of: "func confirmDeletion(", in: code))
        XCTAssertTrue(confirm.hasPrefix(
            "guardletfrozen=pending,acknowledgesPermanentDeletion,acknowledgesSimulatorDataReviewed,phase==.loadedelse{return}"
        ), confirm)
        XCTAssertTrue(confirm.contains("awaitservice.delete(frozen)"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "service.delete(", in: try XCTUnwrap(compact[controller])), 1)
    }

    private static func count(_ expression: NSRegularExpression, in text: String) -> Int {
        expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Types, extensions and refining protocols whose inheritance clause names
    /// `CleanupPermanentDeleting`. Generic parameters are skipped by matching
    /// angle brackets (nested ones included, `->` ignored); a generic
    /// constraint or a where clause is not conformance.
    private static func permanentDeleters(in code: [String: String]) -> [String] {
        let declaration = try! NSRegularExpression(
            pattern: #"\b(?:struct|class|actor|enum|extension|protocol)\s+([A-Za-z_][\w.]*)"#)
        var names: [String] = []
        for (_, text) in code.sorted(by: { $0.key < $1.key }) {
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let name = Range(match.range(at: 1), in: text) else { continue }
                var index = name.upperBound
                func skipWhitespace() {
                    while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
                }
                skipWhitespace()
                if index < text.endIndex, text[index] == "<" {
                    var depth = 0, previous: Character = " "
                    repeat {
                        if text[index] == "<" { depth += 1 } else if text[index] == ">", previous != "-" { depth -= 1 }
                        previous = text[index]
                        index = text.index(after: index)
                    } while depth > 0 && index < text.endIndex
                    skipWhitespace()
                }
                guard index < text.endIndex, text[index] == ":",
                      let open = text[index...].firstIndex(of: "{") else { continue }
                var inherited = text[text.index(after: index)..<open]
                if let constraints = inherited.range(of: #"\bwhere\b"#, options: .regularExpression) {
                    inherited = inherited[..<constraints.lowerBound]
                }
                if inherited.split(separator: ",").contains(where: {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").last == "CleanupPermanentDeleting"
                }) {
                    names.append(String(text[name]))
                }
            }
        }
        return names
    }
}
