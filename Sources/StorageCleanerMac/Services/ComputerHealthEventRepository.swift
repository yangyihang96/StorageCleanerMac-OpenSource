import Foundation

protocol ComputerHealthEventPersisting: Sendable {
    func recordChanges(_ snapshot: ComputerHealthSnapshot) async throws -> ComputerHealthEventRecording
}

enum ComputerHealthEventRepositoryError: Error {
    case invalidDate
    case invalidJournal
    case journalTooLarge
}

/// One atomic local document keeps both the last observation and 200 events.
/// Daily score history remains unchanged: changes within a day are retained.
actor ComputerHealthEventRepository: ComputerHealthEventPersisting {
    static let maximumEntryCount = 200
    static let maximumEvidenceLength = 256
    static let maximumStorageBytes = 524_288
    static let defaultStorageURL = AppDataDirectories.applicationSupportRoot
        .appendingPathComponent("computer-health-events.json", isDirectory: false)
    static let shared = ComputerHealthEventRepository()

    private struct Journal: Codable {
        var version = 1
        var checkedAt: Date?
        var previous: [ComputerHealthCheckObservation] = []
        var events: [ComputerHealthChangeEvent] = []
    }

    private let storageURL: URL

    init(storageURL: URL = ComputerHealthEventRepository.defaultStorageURL) {
        self.storageURL = storageURL
    }

    func load() throws -> [ComputerHealthChangeEvent] {
        try readJournal().events
    }

    func record(_ snapshot: ComputerHealthSnapshot) async throws -> [ComputerHealthChangeEvent] {
        try await recordChanges(snapshot).events
    }

    func recordChanges(_ snapshot: ComputerHealthSnapshot) async throws -> ComputerHealthEventRecording {
        try Task.checkCancellation()
        guard snapshot.generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ComputerHealthEventRepositoryError.invalidDate
        }
        var journal: Journal
        var recovered = false
        do {
            journal = try readJournal()
        } catch where Self.isUnrecognizedJournal(error) {
            // Keep the original bytes beside the journal, then start a new
            // baseline. I/O and permission errors still fail without writing.
            try Task.checkCancellation()
            try moveUnrecognizedJournalAside()
            journal = Journal()
            recovered = true
        }
        // Older completions cannot roll the baseline back or invent changes.
        if let checkedAt = journal.checkedAt, snapshot.generatedAt <= checkedAt {
            return ComputerHealthEventRecording(events: journal.events, recoveredUnrecognizedJournal: recovered)
        }
        let current = ComputerHealthCheckObservation.observations(from: snapshot)
        var changes: [ComputerHealthChangeEvent] = []
        for value in current where !value.state.isIndeterminate {
            if let old = journal.previous.first(where: { $0.check == value.check }), !old.state.isIndeterminate,
               old.state != value.state {
                changes.append(ComputerHealthChangeEvent(id: UUID(), recordedAt: snapshot.generatedAt,
                    check: value.check, oldState: old.state, newState: value.state,
                    evidence: value.evidence.bounded(to: Self.maximumEvidenceLength)))
            }
        }
        // First observation establishes a baseline; changed evidence alone is
        // not a state transition. Missing checks do not become fake changes.
        // Unknown/unreadable reads neither log nor replace the last
        // determinate state, so enabled → (timeout) → enabled stays silent
        // and enabled → (timeout) → disabled records one enabled → disabled.
        for value in current where !value.state.isIndeterminate {
            journal.previous.removeAll { $0.check == value.check }
            journal.previous.append(ComputerHealthCheckObservation(check: value.check, state: value.state,
                evidence: value.evidence.bounded(to: Self.maximumEvidenceLength)))
        }
        journal.checkedAt = snapshot.generatedAt
        journal.events = Array((changes + journal.events).prefix(Self.maximumEntryCount))
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= Self.maximumStorageBytes else { throw ComputerHealthEventRepositoryError.journalTooLarge }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: storageURL, options: .atomic)
        return ComputerHealthEventRecording(events: journal.events, recoveredUnrecognizedJournal: recovered)
    }

    private static func isUnrecognizedJournal(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        if let error = error as? ComputerHealthEventRepositoryError {
            return error == .invalidJournal || error == .journalTooLarge
        }
        return false
    }

    /// `<name>.corrupt-<UTC time>` in the same directory; never overwrites.
    private func moveUnrecognizedJournalAside() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = storageURL.deletingLastPathComponent()
        var backup = directory.appendingPathComponent(storageURL.lastPathComponent + ".corrupt-" + stamp)
        if FileManager.default.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent(storageURL.lastPathComponent + ".corrupt-" + stamp
                + "-" + UUID().uuidString.prefix(8))
        }
        try FileManager.default.moveItem(at: storageURL, to: backup)
    }

    private func readJournal() throws -> Journal {
        let data: Data
        do { data = try Data(contentsOf: storageURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError { return Journal() }
        guard data.count <= Self.maximumStorageBytes else { throw ComputerHealthEventRepositoryError.journalTooLarge }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        guard journal.version == 1, journal.events.count <= Self.maximumEntryCount,
              journal.previous.count <= ComputerHealthEventCheck.allCases.count,
              Set(journal.previous.map(\.check)).count == journal.previous.count,
              journal.previous.allSatisfy({ $0.evidence.freeTextLength <= Self.maximumEvidenceLength }),
              journal.checkedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              journal.events.allSatisfy({
                  $0.recordedAt.timeIntervalSinceReferenceDate.isFinite && $0.oldState != $0.newState
                    && $0.evidence.freeTextLength <= Self.maximumEvidenceLength
              }) else { throw ComputerHealthEventRepositoryError.invalidJournal }
        return journal
    }
}
