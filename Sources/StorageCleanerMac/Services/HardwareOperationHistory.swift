import FanControlShared
import Foundation

/// D102 L4: one hardware write (fans, power mode, Mac mini mode), or an
/// automatic return to system control the app learned of. It holds what was
/// asked, the requested values and the result, nothing else: no serial
/// number, hardware UUID, computer name, profile name or helper message.
struct HardwareOperationRecord: Codable, Equatable, Identifiable, Sendable {
    enum Operation: String, Codable, CaseIterable, Sendable {
        case fanSpeed
        case fanCurveOn
        case fanCurveUpdate
        case fanCurveOff
        case systemFanControl
        case powerMode
        case macMiniMode
    }

    enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
        /// The request left the app but no usable reply came back (timeout,
        /// lost or refused connection, or a reply that did not match the
        /// request), so the result is unknown. A request stopped in the app
        /// before it was sent is not recorded.
        case unconfirmed
        /// The helper reported that it returned the fans to system control on
        /// its own (for example when the app stopped renewing its lease) and
        /// that the return completed.
        case automaticRestore
        /// D105 (review C-R1): the helper reported that it tried to return the
        /// fans to system control on its own and the return did not complete.
        case automaticRestoreFailed
        /// D105 (review C-R1): a reply gave a reason the helper returns the
        /// fans to system control (a lease that ran out, thermal protection)
        /// but no result. A reason alone does not show the return completed.
        case automaticRestoreUnconfirmed
    }

    let id: UUID
    let recordedAt: Date
    let operation: Operation
    let outcome: Outcome
    /// Requested RPM by fan number, for a fan speed write.
    let targetRPMByFan: [Int: Int]?
    /// Fans handed back to system control by the same write.
    let automaticFanIDs: [Int]?
    /// The `pmset` setting and value, and which power source they apply to.
    let powerSetting: String?
    let powerValue: Int?
    let powerSource: String?
    let macMiniMode: MacMiniMode?
    /// The helper's error code (`FanControlHelperErrorCode`), when it gave one.
    let errorCode: String?
    /// D105: why the helper returned the fans on its own, for a return it reported.
    let automaticRestoreReason: FanControlAutomaticRestore.Reason?

    init(id: UUID = UUID(), recordedAt: Date, operation: Operation, outcome: Outcome,
         targetRPMByFan: [Int: Int]? = nil, automaticFanIDs: [Int]? = nil,
         powerSetting: String? = nil, powerValue: Int? = nil, powerSource: String? = nil,
         macMiniMode: MacMiniMode? = nil, errorCode: String? = nil,
         automaticRestoreReason: FanControlAutomaticRestore.Reason? = nil) {
        self.id = id; self.recordedAt = recordedAt; self.operation = operation; self.outcome = outcome
        self.targetRPMByFan = targetRPMByFan; self.automaticFanIDs = automaticFanIDs
        self.powerSetting = powerSetting; self.powerValue = powerValue; self.powerSource = powerSource
        self.macMiniMode = macMiniMode; self.errorCode = errorCode
        self.automaticRestoreReason = automaticRestoreReason
    }

    /// D105 (review C-R2): a return the helper reported, with its own ID and
    /// time, so the same return reported again is the same record.
    init(automaticRestore restore: FanControlAutomaticRestore) {
        self.init(id: restore.id, recordedAt: restore.occurredAt, operation: .systemFanControl,
                  outcome: restore.restored ? .automaticRestore : .automaticRestoreFailed,
                  automaticRestoreReason: restore.reason)
    }
}

/// The local record of hardware operations, newest first. Same storage as
/// ComputerHealthEventRepository: one atomic document, a record count and a
/// byte limit, and a damaged file kept aside rather than overwritten. The
/// app writes it; the root helper never writes to the user's folders, and
/// nothing is sent anywhere.
actor HardwareOperationHistory {
    static let maximumRecordCount = 200
    static let maximumStorageBytes = 131_072
    static let defaultStorageURL = AppDataDirectories.applicationSupportRoot
        .appendingPathComponent("hardware-operations.json", isDirectory: false)
    static let shared = HardwareOperationHistory()

    private struct Document: Codable {
        var version = 1
        var records: [HardwareOperationRecord] = []
    }

    private enum DocumentError: Error { case unrecognized }

    private let storageURL: URL

    init(storageURL: URL = HardwareOperationHistory.defaultStorageURL) {
        self.storageURL = storageURL
    }

    func load() throws -> [HardwareOperationRecord] {
        try readDocument().records
    }

    /// Adds `record` in time order, newest first, so writes that arrive out
    /// of order still list by time. The oldest records go when there are more
    /// than the count limit, or when the document would pass the byte limit.
    /// A record already kept (the same ID, as for a return the helper reports
    /// again on a later reply) is not added twice.
    func record(_ record: HardwareOperationRecord) throws {
        var document: Document
        do {
            document = try readDocument()
        } catch where Self.isUnrecognized(error) {
            try moveUnrecognizedDocumentAside()
            document = Document()
        }
        guard !document.records.contains(where: { $0.id == record.id }) else { return }
        let position = document.records.firstIndex { $0.recordedAt <= record.recordedAt } ?? document.records.endIndex
        document.records.insert(record, at: position)
        document.records = Array(document.records.prefix(Self.maximumRecordCount))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(document)
        while data.count > Self.maximumStorageBytes, !document.records.isEmpty {
            document.records.removeLast()
            data = try encoder.encode(document)
        }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: storageURL, options: .atomic)
    }

    private func readDocument() throws -> Document {
        // Refuses a link in place of the file and anything over the limit.
        guard let data = try BoundedMonitoringFile.read(storageURL, maximumBytes: Self.maximumStorageBytes) else {
            return Document()
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.records.count <= Self.maximumRecordCount,
              document.records.allSatisfy({ $0.recordedAt.timeIntervalSinceReferenceDate.isFinite }) else {
            throw DocumentError.unrecognized
        }
        return document
    }

    private static func isUnrecognized(_ error: Error) -> Bool {
        error is DecodingError || error is DocumentError || (error as? MonitoringFileError) == .oversized
    }

    /// `<name>.corrupt-<UTC time>` in the same folder; never overwrites.
    private func moveUnrecognizedDocumentAside() throws {
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
}

extension HardwareOperationRecord {
    /// The record for a helper request and its reply (nil when none came
    /// back), or nil for requests that only read or renew. Built from the
    /// request's own fields and the reply's error code; the reply's message is
    /// never kept. The helper's own returns to system control that a reply
    /// reports are recorded from that report, one record each (D105).
    static func make(for request: FanControlHelperRequest, reply: FanControlHelperReply?,
                     at date: Date) -> HardwareOperationRecord? {
        let errorCode = reply?.errorCode
        // D105 (review C-R1): the reason alone does not show the return
        // completed; the helper sends the reason whether or not it did.
        if let errorCode, errorCode.isAutomaticRestore, reply?.automaticRestores == nil {
            return HardwareOperationRecord(recordedAt: date, operation: .systemFanControl,
                                           outcome: .automaticRestoreUnconfirmed, errorCode: errorCode.rawValue)
        }
        let operation: Operation
        switch request.operation {
        case .apply: operation = .fanSpeed
        case .activateFanCurve: operation = .fanCurveOn
        case .updateFanCurve: operation = .fanCurveUpdate
        case .deactivateFanCurve: operation = .fanCurveOff
        case .restoreAutomatic: operation = .systemFanControl
        case .applyPowerMode: operation = .powerMode
        case .setMacMiniMode: operation = .macMiniMode
        case .ping, .readPowerConfiguration, .renewFanControlLease, .validateFanCurve,
             .getFanCurveRuntimeState, .readMacMiniMode, .samplePowerMetrics:
            return nil
        }
        return HardwareOperationRecord(
            recordedAt: date, operation: operation,
            outcome: reply.map { $0.success ? .succeeded : .failed } ?? .unconfirmed,
            targetRPMByFan: operation == .fanSpeed ? request.targetRPMByFan : nil,
            automaticFanIDs: operation == .fanSpeed && !request.automaticFanIDs.isEmpty ? request.automaticFanIDs : nil,
            powerSetting: operation == .powerMode ? request.powerModeSetting : nil,
            powerValue: operation == .powerMode ? request.powerModeValue : nil,
            powerSource: operation == .powerMode ? request.powerModeSource : nil,
            macMiniMode: operation == .macMiniMode ? request.macMiniMode : nil,
            errorCode: errorCode?.rawValue)
    }
}

extension FanControlHelperErrorCode {
    /// Replies giving a reason the helper returns the fans to system control
    /// on its own. They do not say whether the return completed.
    var isAutomaticRestore: Bool {
        [.fanLeaseExpired, .curveLeaseExpired, .thermalProtectionActivated].contains(self)
    }
}
