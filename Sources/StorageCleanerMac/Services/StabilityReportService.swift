import Foundation
import os

struct StabilityFileMetadata: Equatable, Sendable {
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let modificationDate: Date?
}

protocol StabilityFileAccessing {
    func metadata(for url: URL) throws -> StabilityFileMetadata
    func contents(of directory: URL) throws -> [URL]
    func readPrefix(of file: URL, maxBytes: Int) throws -> Data
}

struct FileManagerStabilityFileAccess: StabilityFileAccessing {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func metadata(for url: URL) throws -> StabilityFileMetadata {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ])
        return StabilityFileMetadata(
            isDirectory: values.isDirectory == true,
            isRegularFile: values.isRegularFile == true,
            isSymbolicLink: values.isSymbolicLink == true,
            modificationDate: values.contentModificationDate
        )
    }

    func contents(of directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
    }

    func readPrefix(of file: URL, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }
}

struct StabilityReportService {
    static let maximumFiles = 500
    static let maximumBytesPerFile = 64 * 1_024
    static let maximumTotalBytes = 8 * 1_024 * 1_024
    static let maximumWallTime: TimeInterval = 2
    private static let maximumIPSHeaderBytes = 8 * 1_024
    private static let crashReportBugTypes: Set<String> = ["309"]
    private static let scanQueue = DispatchQueue(
        label: "com.local.StorageCleanerMac.stability-scan",
        qos: .utility
    )
    private static let scanInFlight = OSAllocatedUnfairLock(initialState: false)

    private let roots: [URL]
    private let fileAccess: any StabilityFileAccessing
    private let calendar: Calendar
    private let now: () -> Date
    private let monotonicNow: () -> TimeInterval
    private let wallTimeLimit: TimeInterval
    private let enqueueWork: (DispatchWorkItem) -> Void

    init(
        roots: [URL] = Self.defaultRoots,
        fileAccess: any StabilityFileAccessing = FileManagerStabilityFileAccess(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallTimeLimit: TimeInterval = Self.maximumWallTime,
        enqueueWork: @escaping (DispatchWorkItem) -> Void = { workItem in
            StabilityReportService.scanQueue.async(execute: workItem)
        }
    ) {
        self.roots = roots
        self.fileAccess = fileAccess
        self.calendar = calendar
        self.now = now
        self.monotonicNow = monotonicNow
        self.wallTimeLimit = min(max(wallTimeLimit, 0), Self.maximumWallTime)
        self.enqueueWork = enqueueWork
    }

    func snapshot(windowDays: Int = 30) -> StabilitySummary {
        let generatedAt = now()
        let clampedDays = min(max(windowDays, 1), 30)
        let windowStart = calendar.date(
            byAdding: .day,
            value: -clampedDays,
            to: generatedAt
        ) ?? generatedAt.addingTimeInterval(TimeInterval(-clampedDays * 86_400))
        let acquiredScanSlot = Self.scanInFlight.withLock { inFlight in
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard acquiredScanSlot else {
            return Self.timedOutSummary(
                windowStart: windowStart,
                generatedAt: generatedAt
            )
        }
        let result = OSAllocatedUnfairLock(initialState: Optional<StabilitySummary>.none)
        let active = OSAllocatedUnfairLock(initialState: true)
        let workItem = DispatchWorkItem {
            defer { Self.scanInFlight.withLock { $0 = false } }
            guard active.withLock({ $0 }) else { return }
            let summary = scanSnapshot(
                windowStart: windowStart,
                generatedAt: generatedAt
            )
            guard active.withLock({ $0 }) else { return }
            result.withLock { $0 = summary }
        }
        enqueueWork(workItem)
        let waitResult = workItem.wait(
            timeout: .now() + wallTimeLimit
        )
        if waitResult == .success,
           let completed = result.withLock({ $0 }) {
            return completed
        }
        active.withLock { $0 = false }
        return Self.timedOutSummary(
            windowStart: windowStart,
            generatedAt: generatedAt
        )
    }

    private static func timedOutSummary(
        windowStart: Date,
        generatedAt: Date
    ) -> StabilitySummary {
        return StabilitySummary(
            availability: .timedOut,
            status: .unavailable,
            crashCount: nil,
            hangCount: nil,
            spinCount: nil,
            panicCount: nil,
            unexpectedRestartCount: nil,
            filesExamined: 0,
            windowStart: windowStart,
            generatedAt: generatedAt
        )
    }

    private func scanSnapshot(
        windowStart: Date,
        generatedAt: Date
    ) -> StabilitySummary {
        let startedAt = monotonicNow()
        var state = ScanState()
        var candidates = [Candidate]()
        var directories = [URL]()
        var visitedDirectories = Set<URL>()

        func deadlineExceeded() -> Bool {
            monotonicNow() - startedAt >= Self.maximumWallTime
        }

        for root in roots {
            if deadlineExceeded() {
                state.timedOut = true
                break
            }
            do {
                let metadata = try fileAccess.metadata(for: root)
                guard !metadata.isSymbolicLink else {
                    state.hadPartialRead = true
                    continue
                }
                if metadata.isDirectory {
                    state.accessibleRoots = Self.saturatedIncrement(state.accessibleRoots)
                    directories.append(root)
                } else if metadata.isRegularFile {
                    state.accessibleRoots = Self.saturatedIncrement(state.accessibleRoots)
                    appendCandidate(
                        root,
                        metadata: metadata,
                        windowStart: windowStart,
                        generatedAt: generatedAt,
                        candidates: &candidates,
                        state: &state
                    )
                } else {
                    state.hadPartialRead = true
                }
            } catch {
                if Self.isMissingRoot(error) {
                    state.accessibleRoots = Self.saturatedIncrement(state.accessibleRoots)
                } else {
                    state.record(error)
                }
            }
        }

        while !directories.isEmpty, !state.timedOut {
            if deadlineExceeded() {
                state.timedOut = true
                break
            }
            let directory = directories.removeLast()
            let identity = directory.standardizedFileURL
            guard visitedDirectories.insert(identity).inserted else { continue }
            let children: [URL]
            do {
                children = try fileAccess.contents(of: directory)
            } catch {
                state.record(error)
                continue
            }
            for child in children {
                if deadlineExceeded() {
                    state.timedOut = true
                    break
                }
                do {
                    let metadata = try fileAccess.metadata(for: child)
                    if metadata.isSymbolicLink {
                        continue
                    }
                    if metadata.isDirectory {
                        directories.append(child)
                    } else if metadata.isRegularFile {
                        appendCandidate(
                            child,
                            metadata: metadata,
                            windowStart: windowStart,
                            generatedAt: generatedAt,
                            candidates: &candidates,
                            state: &state
                        )
                    }
                } catch {
                    state.record(error)
                }
            }
        }

        candidates.sort {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate > $1.modificationDate
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        if candidates.count > Self.maximumFiles {
            state.hadPartialRead = true
        }

        for candidate in candidates.prefix(Self.maximumFiles) {
            if deadlineExceeded() {
                state.timedOut = true
                break
            }
            var header = Data()
            if candidate.url.pathExtension.lowercased() == "ips" {
                let remainingBytes = Self.maximumTotalBytes - state.totalBytesRead
                guard remainingBytes > 0 else {
                    state.hadPartialRead = true
                    continue
                }
                let readLimit = min(
                    Self.maximumIPSHeaderBytes,
                    Self.maximumBytesPerFile,
                    remainingBytes
                )
                do {
                    let data = try fileAccess.readPrefix(of: candidate.url, maxBytes: readLimit)
                    header = data.count <= readLimit ? data : Data(data.prefix(readLimit))
                    state.totalBytesRead += header.count
                } catch {
                    state.record(error)
                    continue
                }
            }
            state.filesExamined = Self.saturatedIncrement(state.filesExamined)
            guard let event = Self.classify(candidate.url, header: header) else {
                state.hadPartialRead = true
                continue
            }
            state.record(event, occurredAt: candidate.modificationDate)
        }

        return Self.summary(
            from: state,
            windowStart: windowStart,
            generatedAt: generatedAt
        )
    }

    private struct Candidate {
        let url: URL
        let modificationDate: Date
    }

    private enum EventKind {
        case crash
        case hang
        case spin
        case panic
        case unexpectedRestart
    }

    private struct ScanState {
        var crashCount = 0
        var hangCount = 0
        var spinCount = 0
        var panicCount = 0
        var unexpectedRestartCount = 0
        var events: [StabilityEvent] = []
        var filesExamined = 0
        var totalBytesRead = 0
        var accessibleRoots = 0
        var sawPermissionDenied = false
        var sawUnavailable = false
        var hadPartialRead = false
        var timedOut = false

        mutating func record(_ event: EventKind, occurredAt: Date) {
            let eventType: StabilityEventType
            switch event {
            case .crash:
                crashCount = StabilityReportService.saturatedIncrement(crashCount)
                eventType = .crash
            case .hang:
                hangCount = StabilityReportService.saturatedIncrement(hangCount)
                eventType = .hang
            case .spin:
                spinCount = StabilityReportService.saturatedIncrement(spinCount)
                eventType = .spin
            case .panic:
                panicCount = StabilityReportService.saturatedIncrement(panicCount)
                eventType = .panic
            case .unexpectedRestart:
                unexpectedRestartCount = StabilityReportService.saturatedIncrement(
                    unexpectedRestartCount
                )
                eventType = .unexpectedRestart
            }
            events.append(StabilityEvent(type: eventType, occurredAt: occurredAt))
        }

        mutating func record(_ error: Error) {
            if StabilityReportService.isPermissionDenied(error) {
                sawPermissionDenied = true
            } else {
                sawUnavailable = true
            }
            if accessibleRoots > 0 {
                hadPartialRead = true
            }
        }
    }

    private static var defaultRoots: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
        ]
    }

    private func appendCandidate(
        _ url: URL,
        metadata: StabilityFileMetadata,
        windowStart: Date,
        generatedAt: Date,
        candidates: inout [Candidate],
        state: inout ScanState
    ) {
        guard Self.isEligibleReport(url) else { return }
        guard let modificationDate = metadata.modificationDate else {
            state.hadPartialRead = true
            return
        }
        guard modificationDate >= windowStart else { return }
        guard modificationDate <= generatedAt.addingTimeInterval(86_400) else {
            state.hadPartialRead = true
            return
        }
        candidates.append(Candidate(url: url, modificationDate: modificationDate))
    }

    private static func isEligibleReport(_ url: URL) -> Bool {
        let fileName = url.lastPathComponent.lowercased()
        let fileExtension = url.pathExtension.lowercased()
        if ["ips", "crash", "hang", "spin", "panic"].contains(fileExtension) {
            return true
        }
        return isExplicitPanicName(fileName)
            || isExplicitShutdownStallName(fileName)
            || isExplicitRestartName(fileName)
    }

    private static func classify(_ url: URL, header: Data) -> EventKind? {
        let fileName = url.lastPathComponent.lowercased()
        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "panic" || isExplicitPanicName(fileName) {
            return .panic
        }
        if isExplicitShutdownStallName(fileName) {
            return .hang
        }
        if isExplicitRestartName(fileName) {
            return .unexpectedRestart
        }
        switch fileExtension {
        case "crash":
            return .crash
        case "hang":
            return .hang
        case "spin":
            return .spin
        case "ips":
            return classifyIPSHeader(header)
        default:
            return nil
        }
    }

    private static func classifyIPSHeader(_ data: Data) -> EventKind? {
        guard let text = String(data: data.prefix(maximumIPSHeaderBytes), encoding: .utf8) else {
            return nil
        }
        guard let firstLine = text.split(whereSeparator: \Character.isNewline).first else { return nil }
        guard let jsonData = String(firstLine).data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        let safeTypeValues = ["report_type", "reportType", "type", "incident_type"]
            .compactMap { dictionary[$0] as? String }
            .map { $0.lowercased() }
        if safeTypeValues.contains(where: { $0.contains("panic") }) {
            return .panic
        }
        if safeTypeValues.contains(where: { $0.contains("shutdown stall") }) {
            return .hang
        }
        if safeTypeValues.contains(where: {
            $0.contains("unexpected restart") || $0.contains("sleep wake failure")
        }) {
            return .unexpectedRestart
        }
        if safeTypeValues.contains(where: { $0.contains("hang") }) {
            return .hang
        }
        if safeTypeValues.contains(where: { $0.contains("spin") }) {
            return .spin
        }
        if safeTypeValues.contains(where: { $0.contains("crash") }) {
            return .crash
        }
        if let bugType = normalizedBugType(dictionary["bug_type"]),
           crashReportBugTypes.contains(bugType) {
            return .crash
        }
        return nil
    }

    private static func normalizedBugType(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func isExplicitPanicName(_ fileName: String) -> Bool {
        let compact = normalizedFileName(fileName)
        return compact.contains("kernalpanic")
            || compact.contains("kernelpanic")
            || compact.contains("panicfull")
            || compact.hasPrefix("panic")
    }

    private static func isExplicitRestartName(_ fileName: String) -> Bool {
        let compact = normalizedFileName(fileName)
        return compact.contains("unexpectedrestart")
            || compact.contains("sleepwakefailure")
            || compact.hasPrefix("restart")
    }

    private static func isExplicitShutdownStallName(_ fileName: String) -> Bool {
        normalizedFileName(fileName).contains("shutdownstall")
    }

    private static func normalizedFileName(_ fileName: String) -> String {
        fileName.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func summary(
        from state: ScanState,
        windowStart: Date,
        generatedAt: Date
    ) -> StabilitySummary {
        let availability: HealthAvailability
        if state.timedOut {
            availability = state.filesExamined > 0 ? .partial : .timedOut
        } else if state.accessibleRoots == 0 {
            availability = state.sawPermissionDenied ? .permissionDenied : .unavailable
        } else if state.hadPartialRead || state.sawPermissionDenied || state.sawUnavailable {
            availability = .partial
        } else {
            availability = .available
        }

        let status: HealthStatus
        if availability.hasUsableData {
            if state.panicCount > 0 || state.unexpectedRestartCount > 0 {
                status = .actionRequired
            } else if state.crashCount > 0 || state.hangCount > 0 || state.spinCount > 0 {
                status = .attention
            } else {
                status = .healthy
            }
        } else {
            status = .unavailable
        }

        let hasUsableData = availability.hasUsableData && state.accessibleRoots > 0
        return StabilitySummary(
            availability: availability,
            status: status,
            crashCount: hasUsableData ? state.crashCount : nil,
            hangCount: hasUsableData ? state.hangCount : nil,
            spinCount: hasUsableData ? state.spinCount : nil,
            panicCount: hasUsableData ? state.panicCount : nil,
            unexpectedRestartCount: hasUsableData ? state.unexpectedRestartCount : nil,
            events: hasUsableData ? state.events : [],
            filesExamined: state.filesExamined,
            windowStart: windowStart,
            generatedAt: generatedAt
        )
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain,
           [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue]
            .contains(nsError.code) {
            return true
        }
        return false
    }

    private static func isMissingRoot(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        return nsError.domain == NSCocoaErrorDomain
            && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue]
                .contains(nsError.code)
    }

    static func saturatedIncrement(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }
}
