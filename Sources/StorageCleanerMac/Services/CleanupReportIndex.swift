import Foundation

/// Disposable, bounded listing metadata. Restore always reloads the authoritative
/// journal; this index never grants permission or supplies move receipts.
struct CleanupReportIndex: Codable, Identifiable, Equatable, Sendable {
    var id: UUID { planID.rawValue }
    let planID: CleanPlanID
    let startedAt: Date
    let orderingDate: Date
    let rulesVersion: String
    let outcome: CleanReportOutcome
    let summary: CleanReportSummary
    let recoverableCount: Int
    let needsVerification: Bool
    let presentation: OperationResultPresentation?
    let subject: String?

    init(report: CleanReport, orderingDate: Date) {
        planID = report.planID; startedAt = report.startedAt; self.orderingDate = orderingDate
        rulesVersion = report.rulesVersion; outcome = report.outcome; summary = report.summary
        presentation = OperationResultPresentation(report: report)
        if report.rulesVersion == ExternalDriveMigrationService.originalRuleID {
            // N18: the moved file's name, shown as "File Move · <name>".
            subject = report.items.first
                .map { String(URL(fileURLWithPath: $0.sourcePath).lastPathComponent.prefix(160)) }
        } else if report.rulesVersion == FileAnalysisTrashService.ruleID {
            // D46: the first item's name; the title adds how many there were
            // when it is shown, in the language of that moment.
            subject = report.items.first
                .map { String(URL(fileURLWithPath: $0.sourcePath).lastPathComponent.prefix(160)) }
        } else if ToolboxOperationTitles.prefix(for: report.rulesVersion) != nil {
            subject = ToolboxOperationTitles.subject(rulesVersion: report.rulesVersion,
                                                     firstSourcePath: report.items.first?.sourcePath)
        } else {
            subject = report.items.first(where: { $0.sourcePath.hasSuffix(".app") })
                .map { String(URL(fileURLWithPath: $0.sourcePath).deletingPathExtension().lastPathComponent.prefix(160)) }
        }
        recoverableCount = report.restorableReceipts.count
        needsVerification = report.persistenceFailure != nil || report.items.contains {
            if case .failed(let failure) = $0.outcome {
                return failure.code == .moveOutcomeUnknown || failure.code == .deletionOutcomeUnknown
            }
            return false
        } || (report.recoveryAttempts ?? []).contains {
            $0.persistenceFailure != nil || $0.items.contains { $0.outcome == .outcomeUnknown }
        }
    }
    struct Cursor: Equatable, Sendable { let date: Date; let id: UUID }
    var cursor: Cursor { Cursor(date: orderingDate, id: id) }
    func follows(_ cursor: Cursor?) -> Bool {
        guard let cursor else { return true }
        return orderingDate < cursor.date || (orderingDate == cursor.date && id.uuidString < cursor.id.uuidString)
    }
    static func newestFirst(_ a: Self, _ b: Self) -> Bool {
        a.orderingDate == b.orderingDate ? a.id.uuidString > b.id.uuidString : a.orderingDate > b.orderingDate
    }
}

extension CleanupReportJournal {
    struct SummaryPage: Sendable {
        let reports: [CleanupReportIndex]
        let next: CleanupReportIndex.Cursor?
        let unreadableEntries: [String]
    }
    private struct IndexEnvelope: Codable {
        let version: Int
        let baseBytes: Int
        let eventBytes: Int
        let modifiedAt: Date
        let value: CleanupReportIndex
    }

    func reportURL(for planID: CleanPlanID) -> URL {
        directory.appendingPathComponent(planID.rawValue.uuidString).appendingPathExtension("json")
    }

    func read(planID: CleanPlanID) throws -> CleanReport { try read(reportURL(for: planID)).report }

    /// Cache failure must not turn a durable operation into a reported failure.
    /// Stamps make stale or partially updated caches fall back to journal replay.
    func refreshIndex(_ report: CleanReport) {
        let base = reportURL(for: report.planID)
        guard let stamp = try? indexStamp(base),
              !PathSafety.containsSymbolicLinkComponent(in: directory.path) else { return }
        let url = base.deletingPathExtension().appendingPathExtension("index")
        if FileManager.default.fileExists(atPath: url.path), PathSafety.containsSymbolicLinkComponent(in: url.path) { return }
        let envelope = IndexEnvelope(version: 3, baseBytes: stamp.base, eventBytes: stamp.events,
            modifiedAt: stamp.date, value: CleanupReportIndex(report: report, orderingDate: stamp.date))
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Only the disposable index is unavailable. */ }
    }

    func summaryPage(after cursor: CleanupReportIndex.Cursor? = nil, limit requestedLimit: Int = 40) throws -> SummaryPage {
        let limit = min(100, max(1, requestedLimit))
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return SummaryPage(reports: [], next: nil, unreadableEntries: [])
        }
        guard !PathSafety.containsSymbolicLinkComponent(in: directory.path) else { throw Failure.unsafePath }
        // Enumerate names without materializing the complete directory or reports.
        guard let files = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { throw Failure.unsafePath }
        var candidates: [(url: URL, date: Date, id: UUID)] = []
        var unreadable: [String] = []
        for case let url as URL in files where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let stamp = try? indexStamp(url) else {
                if unreadable.count < 40 { unreadable.append(url.lastPathComponent) }; continue
            }
            if let cursor, !(stamp.date < cursor.date || (stamp.date == cursor.date && id.uuidString < cursor.id.uuidString)) { continue }
            candidates.append((url, stamp.date, id))
            candidates.sort { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }
            if candidates.count > limit + 1 { candidates.removeLast() }
        }
        let selected = Array(candidates.prefix(limit))
        var reports: [CleanupReportIndex] = []
        for candidate in selected {
            do {
                if let cached = try cachedIndex(candidate.url) { reports.append(cached) }
                else {
                    let evidence = try readWithEvents(candidate.url)
                    reports.append(CleanupReportIndex(report: evidence.entry.report, orderingDate: candidate.date))
                    if evidence.damagedSuffix { unreadable.append(CleanupJournalEvents.eventURL(for: candidate.url).lastPathComponent) }
                }
            } catch { unreadable.append(candidate.url.lastPathComponent) }
        }
        return SummaryPage(reports: reports, next: candidates.count > limit ? selected.last.map {
            CleanupReportIndex.Cursor(date: $0.date, id: $0.id)
        } : nil, unreadableEntries: unreadable)
    }

    private func cachedIndex(_ base: URL) throws -> CleanupReportIndex? {
        let url = base.deletingPathExtension().appendingPathExtension("index")
        guard FileManager.default.fileExists(atPath: url.path),
              !PathSafety.containsSymbolicLinkComponent(in: url.path),
              let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 32_768,
              let entry = try? JSONDecoder().decode(IndexEnvelope.self, from: Data(contentsOf: url)),
              entry.version == 3, entry.value.planID.rawValue.uuidString == base.deletingPathExtension().lastPathComponent else { return nil }
        let stamp = try indexStamp(base)
        guard stamp.base == entry.baseBytes, stamp.events == entry.eventBytes, stamp.date == entry.modifiedAt else { return nil }
        return entry.value
    }
    private func indexStamp(_ base: URL) throws -> (base: Int, events: Int, date: Date) {
        guard !PathSafety.containsSymbolicLinkComponent(in: base.path) else { throw Failure.unsafePath }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let a = try base.resourceValues(forKeys: keys)
        guard a.isRegularFile == true, let baseBytes = a.fileSize, let date = a.contentModificationDate else { throw Failure.invalidEntry }
        let events = CleanupJournalEvents.eventURL(for: base)
        guard FileManager.default.fileExists(atPath: events.path) else { return (baseBytes, 0, date) }
        guard !PathSafety.containsSymbolicLinkComponent(in: events.path) else { throw Failure.unsafePath }
        let b = try events.resourceValues(forKeys: keys)
        guard b.isRegularFile == true, let eventBytes = b.fileSize, let eventDate = b.contentModificationDate else { throw Failure.invalidEntry }
        return (baseBytes, eventBytes, max(date, eventDate))
    }
}
