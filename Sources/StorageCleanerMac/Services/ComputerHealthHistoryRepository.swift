import Darwin
import Foundation

protocol ComputerHealthHistoryPersisting: Sendable {
    func load() async -> [ComputerHealthHistoryEntry]
    func save(_ entry: ComputerHealthHistoryEntry) async throws
}

enum ComputerHealthHistoryRepositoryError: Error, Equatable {
    case invalidEntry
    case atomicReplacementFailed(Int32)
}

actor ComputerHealthHistoryRepository: ComputerHealthHistoryPersisting {
    static let maximumEntryCount = 90
    static let defaultStorageURL: URL = {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("computer-health-history.json", isDirectory: false)
    }()

    private let storageURL: URL
    private let calendar: Calendar
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        storageURL: URL = ComputerHealthHistoryRepository.defaultStorageURL,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) {
        self.storageURL = storageURL
        self.calendar = calendar
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func load() async -> [ComputerHealthHistoryEntry] {
        boundedAndSanitized(readEntries())
    }

    func save(_ entry: ComputerHealthHistoryEntry) async throws {
        guard isValid(entry) else {
            throw ComputerHealthHistoryRepositoryError.invalidEntry
        }

        var entries = readEntries()
        entries.append(privacySanitized(entry))
        let normalized = boundedAndSanitized(entries)
        try persist(normalized)
    }

    private func readEntries() -> [ComputerHealthHistoryEntry] {
        guard let data = try? Data(contentsOf: storageURL),
              let entries = try? decoder.decode([ComputerHealthHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func boundedAndSanitized(
        _ entries: [ComputerHealthHistoryEntry]
    ) -> [ComputerHealthHistoryEntry] {
        var latestByDay: [Date: ComputerHealthHistoryEntry] = [:]
        for entry in entries where isValid(entry) {
            let sanitized = privacySanitized(entry)
            let day = calendar.startOfDay(for: sanitized.recordedAt)
            if let existing = latestByDay[day],
               existing.recordedAt > sanitized.recordedAt
            {
                continue
            }
            latestByDay[day] = sanitized
        }

        let newestFirst = latestByDay.values.sorted { lhs, rhs in
            if lhs.recordedAt == rhs.recordedAt {
                return lhs.modelVersion < rhs.modelVersion
            }
            return lhs.recordedAt > rhs.recordedAt
        }
        guard let newest = newestFirst.first else { return [] }
        let newestDay = calendar.startOfDay(for: newest.recordedAt)
        guard let cutoffDay = calendar.date(
            byAdding: .day,
            value: -(Self.maximumEntryCount - 1),
            to: newestDay
        ) else { return [] }
        let insideWindow = newestFirst.filter {
            calendar.startOfDay(for: $0.recordedAt) >= cutoffDay
        }
        return Array(insideWindow.prefix(Self.maximumEntryCount))
    }

    private func privacySanitized(
        _ entry: ComputerHealthHistoryEntry
    ) -> ComputerHealthHistoryEntry {
        let components = entry.evaluation.components.map { component in
            HealthComponentEvaluation(
                factor: component.factor,
                availability: component.availability,
                score: component.score,
                evidenceSummary: nil,
                evaluatedAt: component.evaluatedAt,
                modelVersion: component.modelVersion
            )
        }
        let evaluation = ComputerHealthEvaluation(
            score: entry.evaluation.score,
            status: entry.evaluation.status,
            coverage: entry.evaluation.coverage,
            confidence: entry.evaluation.confidence,
            components: components,
            evaluatedAt: entry.evaluation.evaluatedAt,
            modelVersion: entry.evaluation.modelVersion
        )
        return ComputerHealthHistoryEntry(
            recordedAt: entry.recordedAt,
            evaluation: evaluation,
            totalBytes: entry.totalBytes,
            availableForImportantUsageBytes: entry.availableForImportantUsageBytes,
            diskRemainingLifePercent: entry.diskRemainingLifePercent,
            maximumCapacityPercent: entry.maximumCapacityPercent,
            batteryCycleCount: entry.batteryCycleCount,
            latestVerifiedCompleteBackupAt: entry.latestVerifiedCompleteBackupAt,
            modelVersion: entry.modelVersion
        )
    }

    private func isValid(_ entry: ComputerHealthHistoryEntry) -> Bool {
        guard entry.recordedAt.timeIntervalSinceReferenceDate.isFinite,
              entry.evaluation.evaluatedAt.timeIntervalSinceReferenceDate.isFinite,
              entry.evaluation.coverage.isFinite,
              (0...1).contains(entry.evaluation.coverage),
              (0...100).contains(entry.evaluation.confidence.value),
              isValidScore(entry.evaluation.score),
              entry.evaluation.components.allSatisfy(isValidComponent) else {
            return false
        }

        if let totalBytes = entry.totalBytes {
            guard totalBytes > 0 else { return false }
            if let availableBytes = entry.availableForImportantUsageBytes,
               availableBytes < 0 || availableBytes > totalBytes
            {
                return false
            }
        } else if entry.availableForImportantUsageBytes != nil {
            return false
        }

        if let capacity = entry.maximumCapacityPercent,
           !(0...100).contains(capacity)
        {
            return false
        }
        if let remainingLife = entry.diskRemainingLifePercent,
           !(0...100).contains(remainingLife)
        {
            return false
        }
        if let cycles = entry.batteryCycleCount, cycles < 0 {
            return false
        }
        if let backupDate = entry.latestVerifiedCompleteBackupAt,
           !backupDate.timeIntervalSinceReferenceDate.isFinite
        {
            return false
        }
        return true
    }

    private func isValidComponent(_ component: HealthComponentEvaluation) -> Bool {
        component.evaluatedAt.timeIntervalSinceReferenceDate.isFinite
            && isValidScore(component.score)
    }

    private func isValidScore(_ score: Double?) -> Bool {
        guard let score else { return true }
        return score.isFinite && (0...100).contains(score)
    }

    private func persist(_ entries: [ComputerHealthHistoryEntry]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(entries)
        let temporaryURL = directory.appendingPathComponent(
            ".\(storageURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporaryURL)
            let renameResult: Int32 = temporaryURL.withUnsafeFileSystemRepresentation { source in
                storageURL.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination else { return Int32(-1) }
                    return Darwin.rename(source, destination)
                }
            }
            guard renameResult == 0 else {
                throw ComputerHealthHistoryRepositoryError.atomicReplacementFailed(errno)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
