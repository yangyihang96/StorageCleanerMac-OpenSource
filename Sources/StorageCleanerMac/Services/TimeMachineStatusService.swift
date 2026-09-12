import Foundation

struct TimeMachineCommand: Hashable, Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
}

protocol TimeMachineCommandRunning {
    func capture(_ command: TimeMachineCommand) throws -> Data
}

enum TimeMachineCommandFailure: Error, Equatable {
    case unconfigured
    case permissionDenied
    case timedOut
    case cancelled
    case unreachable
    case unavailable
}

struct ShellTimeMachineCommandRunner: TimeMachineCommandRunning {
    private static let outputByteLimit = 1_048_576

    func capture(_ command: TimeMachineCommand) throws -> Data {
        do {
            let output = try Shell.captureCancellable(
                command.executable,
                command.arguments,
                timeout: command.timeout,
                outputByteLimit: Self.outputByteLimit,
                cancellationCheck: {
                    withUnsafeCurrentTask { $0?.isCancelled ?? false }
                }
            )
            return Data(output.utf8)
        } catch is CancellationError {
            throw TimeMachineCommandFailure.cancelled
        } catch ShellError.cancelled {
            throw TimeMachineCommandFailure.cancelled
        } catch ShellError.timedOut {
            throw TimeMachineCommandFailure.timedOut
        } catch {
            throw Self.safeFailure(for: error)
        }
    }

    static func safeFailure(for error: Error) -> TimeMachineCommandFailure {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                return .permissionDenied
            }
            if [ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ENOTCONN]
                .map(Int.init)
                .contains(nsError.code) {
                return .unreachable
            }
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return .permissionDenied
        }
        guard case let ShellError.failed(_, _, output) = error else {
            return .unavailable
        }
        let normalized = output.lowercased()
        if normalized.contains("no destinations configured") {
            return .unconfigured
        }
        if [
            "operation not permitted",
            "permission denied",
            "not authorized",
            "full disk access"
        ].contains(where: normalized.contains) {
            return .permissionDenied
        }
        if [
            "could not be mounted",
            "couldn't be mounted",
            "destination is unavailable",
            "destination not available",
            "network is unreachable",
            "host is down",
            "no route to host",
            "could not connect"
        ].contains(where: normalized.contains) {
            return .unreachable
        }
        return .unavailable
    }
}

struct TimeMachineStatusService {
    static let destinationInfoCommand = TimeMachineCommand(
        executable: "/usr/bin/tmutil",
        arguments: ["destinationinfo", "-X"],
        timeout: 3
    )
    static let statusCommand = TimeMachineCommand(
        executable: "/usr/bin/tmutil",
        arguments: ["status"],
        timeout: 2
    )
    static let localSnapshotsCommand = TimeMachineCommand(
        executable: "/usr/bin/tmutil",
        arguments: ["listlocalsnapshotdates", "/"],
        timeout: 3
    )
    static let latestBackupCommand = TimeMachineCommand(
        executable: "/usr/bin/tmutil",
        arguments: ["latestbackup", "-t"],
        timeout: 5
    )

    private let runner: any TimeMachineCommandRunning
    private let calendar: Calendar
    private let now: () -> Date

    init(
        runner: any TimeMachineCommandRunning = ShellTimeMachineCommandRunner(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.calendar = calendar
        self.now = now
    }

    func snapshot() -> TimeMachineSnapshot {
        let checkedAt = now()
        switch capture(Self.destinationInfoCommand) {
        case let .failure(failure):
            if failure == .unconfigured {
                return unconfiguredSnapshot(checkedAt: checkedAt)
            }
            return unavailableSnapshot(for: failure, checkedAt: checkedAt)
        case let .success(data):
            guard let configured = Self.destinationIsConfigured(in: data) else {
                return unavailableSnapshot(for: .unavailable, checkedAt: checkedAt)
            }
            guard configured else {
                return unconfiguredSnapshot(checkedAt: checkedAt)
            }
        }

        let statusCapture = capture(Self.statusCommand)
        let localCapture = capture(Self.localSnapshotsCommand)
        let completeCapture = capture(Self.latestBackupCommand)

        let running = statusCapture.data.flatMap(Self.runningState)
        let localResult = localCapture.data.map {
            Self.localSnapshotResult(in: $0, calendar: calendar)
        }
        let latestCompleteBackup = completeCapture.data.flatMap {
            Self.latestTimestamp(in: $0, calendar: calendar)
        }
        let completeAvailability: HealthAvailability
        switch completeCapture {
        case .success where latestCompleteBackup != nil:
            completeAvailability = .available
        case .success:
            completeAvailability = .unavailable
        case let .failure(failure):
            completeAvailability = Self.availability(for: failure)
        }

        let hasCompleteStatus = running != nil
        let hasCompleteLocalResult = localResult?.isValid == true
        let hasCompleteBackup = latestCompleteBackup != nil
        let availability: HealthAvailability = hasCompleteStatus
            && hasCompleteLocalResult
            && hasCompleteBackup
            ? .available
            : .partial
        let proposedStatus: HealthStatus = availability == .available ? .healthy : .attention

        return TimeMachineSnapshot(
            availability: availability,
            status: proposedStatus,
            destinationState: .configured,
            isRunning: running,
            latestLocalSnapshot: localResult?.date,
            latestCompleteBackup: latestCompleteBackup,
            completeBackupAvailability: completeAvailability,
            summaryText: availability == .available ? Self.availableSummary : Self.partialSummary,
            checkedAt: checkedAt
        )
    }

    private enum CaptureResult {
        case success(Data)
        case failure(TimeMachineCommandFailure)

        var data: Data? {
            guard case let .success(data) = self else { return nil }
            return data
        }
    }

    private struct LocalSnapshotResult {
        let isValid: Bool
        let date: Date?
    }

    private func capture(_ command: TimeMachineCommand) -> CaptureResult {
        do {
            return .success(try runner.capture(command))
        } catch let failure as TimeMachineCommandFailure {
            return .failure(failure)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.unavailable)
        }
    }

    private func unavailableSnapshot(
        for failure: TimeMachineCommandFailure,
        checkedAt: Date
    ) -> TimeMachineSnapshot {
        TimeMachineSnapshot(
            availability: Self.availability(for: failure),
            status: .unavailable,
            destinationState: Self.destinationState(for: failure),
            isRunning: nil,
            latestLocalSnapshot: nil,
            latestCompleteBackup: nil,
            completeBackupAvailability: .unavailable,
            summaryText: Self.unavailableSummary,
            checkedAt: checkedAt
        )
    }

    private func unconfiguredSnapshot(checkedAt: Date) -> TimeMachineSnapshot {
        TimeMachineSnapshot(
            availability: .available,
            status: .attention,
            destinationState: .unconfigured,
            isRunning: nil,
            latestLocalSnapshot: nil,
            latestCompleteBackup: nil,
            completeBackupAvailability: .unavailable,
            summaryText: Self.unconfiguredSummary,
            checkedAt: checkedAt
        )
    }

    private static func availability(
        for failure: TimeMachineCommandFailure
    ) -> HealthAvailability {
        switch failure {
        case .unconfigured:
            .unavailable
        case .permissionDenied:
            .permissionDenied
        case .timedOut:
            .timedOut
        case .cancelled:
            .cancelled
        case .unreachable, .unavailable:
            .unavailable
        }
    }

    private static func destinationState(
        for failure: TimeMachineCommandFailure
    ) -> TimeMachineDestinationState {
        switch failure {
        case .unconfigured:
            .unconfigured
        case .permissionDenied:
            .permissionDenied
        case .timedOut:
            .timedOut
        case .unreachable:
            .unreachable
        case .cancelled, .unavailable:
            .unavailable
        }
    }

    private static func destinationIsConfigured(in data: Data) -> Bool? {
        if let text = String(data: data, encoding: .utf8),
           text.localizedCaseInsensitiveContains("No destinations configured") {
            return false
        }
        guard let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return nil
        }
        if let destinations = object as? [[String: Any]] {
            if destinations.isEmpty { return false }
            return destinations.contains(where: looksLikeDestination) ? true : nil
        }
        if let dictionary = object as? [String: Any] {
            if dictionary.isEmpty { return false }
            for key in ["Destinations", "destinations"] {
                if let destinations = dictionary[key] as? [[String: Any]] {
                    if destinations.isEmpty { return false }
                    return destinations.contains(where: looksLikeDestination) ? true : nil
                }
            }
            return looksLikeDestination(dictionary) ? true : nil
        }
        return nil
    }

    private static func looksLikeDestination(_ dictionary: [String: Any]) -> Bool {
        let keys = Set(dictionary.keys.map { $0.lowercased() })
        return !keys.isDisjoint(with: [
            "destinationid",
            "destinationurl"
        ])
    }

    private static func runningState(in data: Data) -> Bool? {
        if let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let dictionary = object as? [String: Any], let value = dictionary["Running"] {
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var values = [Bool]()
        var sawRunningKey = false
        for rawLine in text.components(separatedBy: .newlines) {
            let parts = rawLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.caseInsensitiveCompare("Running") == .orderedSame else { continue }
            sawRunningKey = true
            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch value {
            case "1", "true", "yes":
                values.append(true)
            case "0", "false", "no":
                values.append(false)
            default:
                return nil
            }
        }
        guard sawRunningKey, let first = values.first,
              values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func localSnapshotResult(
        in data: Data,
        calendar: Calendar
    ) -> LocalSnapshotResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return LocalSnapshotResult(isValid: false, date: nil)
        }
        let dates = timestamps(in: text, calendar: calendar)
        let hasHeader = text.localizedCaseInsensitiveContains("Snapshots for volume")
        return LocalSnapshotResult(
            isValid: hasHeader || !dates.isEmpty,
            date: dates.max()
        )
    }

    private static func latestTimestamp(in data: Data, calendar: Calendar) -> Date? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 17 else { return nil }
        let dates = timestamps(in: trimmed, calendar: calendar)
        guard dates.count == 1 else { return nil }
        return dates[0]
    }

    private static func timestamps(in text: String, calendar: Calendar) -> [Date] {
        let pattern = #"(?<!\d)\d{4}-\d{2}-\d{2}-\d{6}(?!\d)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        return expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return formatter.date(from: String(text[swiftRange]))
        }
    }

    private static var availableSummary: String {
        L10n.text("Time Machine 状态已检查", "Time Machine status checked")
    }

    private static var partialSummary: String {
        L10n.text("Time Machine 仅提供部分状态", "Time Machine provided partial status")
    }

    private static var unconfiguredSummary: String {
        L10n.text("尚未配置 Time Machine", "Time Machine is not configured")
    }

    private static var unavailableSummary: String {
        L10n.text("无法可靠读取 Time Machine 状态", "Time Machine status is unavailable")
    }
}
