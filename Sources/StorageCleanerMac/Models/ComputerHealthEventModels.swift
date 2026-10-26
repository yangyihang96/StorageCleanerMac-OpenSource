import Foundation

enum ComputerHealthEventCheck: String, Codable, CaseIterable, Sendable {
    case disk, capacity, stability, battery, backup
    case systemIntegrityProtection, fileVault, gatekeeper, firewall

    var title: String {
        if let securityCheck { return securityCheck.title }
        switch self {
        case .disk: return L10n.text("磁盘可靠性", "Disk Reliability")
        case .capacity: return L10n.text("可用容量", "Available Capacity")
        case .stability: return L10n.text("系统稳定性", "System Stability")
        case .battery: return L10n.text("电池寿命", "Battery Lifespan")
        case .backup: return L10n.text("时间机器", "Time Machine")
        default: return L10n.text("安全检查", "Security Check")
        }
    }

    var securityCheck: SystemProtectionCheck? {
        switch self {
        case .systemIntegrityProtection: .systemIntegrityProtection
        case .fileVault: .fileVault
        case .gatekeeper: .gatekeeper
        case .firewall: .firewall
        default: nil
        }
    }
}

enum ComputerHealthCheckState: String, Codable, Sendable {
    case normal, warning, failure, unknown, unreadable, notApplicable
    case enabled, disabled, transitioning

    var title: String {
        switch self {
        case .normal: L10n.text("正常", "Normal")
        case .warning: L10n.text("需关注", "Attention")
        case .failure: L10n.text("异常", "Problem")
        case .unknown: L10n.text("未知", "Unknown")
        case .unreadable: L10n.text("无法读取", "Unreadable")
        case .notApplicable: L10n.text("不适用", "Not Applicable")
        case .enabled: L10n.text("已开启", "On")
        case .disabled: L10n.text("已关闭", "Off")
        case .transitioning: L10n.text("转换中", "Transitioning")
        }
    }

    /// Same wording as the result row: a SMART failure is shown there as
    /// “故障警告” with the warning symbol, so the journal uses that title too.
    func title(for check: ComputerHealthEventCheck) -> String {
        if check == .disk && self == .warning { return L10n.text("故障警告", "Failure warning") }
        return title
    }

    /// Reads that could not establish a state. They never create journal
    /// events nor replace a determinate baseline, so transient load or
    /// timeout noise cannot fill the 200-entry log.
    var isIndeterminate: Bool { self == .unknown || self == .unreadable }

    var protectionState: SystemProtectionState {
        switch self {
        case .enabled: .enabled
        case .disabled: .disabled
        case .transitioning: .transitioning
        case .unreadable: .unreadable
        default: .unknown
        }
    }

    init(status: HealthStatus) {
        self = switch status {
        case .healthy: .normal
        case .attention: .warning
        case .actionRequired: .failure
        case .unavailable: .unreadable
        }
    }

    init(protection: SystemProtectionState) {
        self = switch protection {
        case .enabled: .enabled
        case .disabled: .disabled
        case .transitioning: .transitioning
        case .unreadable: .unreadable
        case .unknown, .detected: .unknown
        }
    }
}

/// Structured journal evidence: codes and numbers only, localized when shown.
enum ComputerHealthEventEvidence: Codable, Equatable, Sendable {
    case status
    case availableBytes(Int64)
    case batteryMaximumCapacity(Int)
    case security(SystemProtectionEvidence)
    /// Text written by an older build before evidence became structured.
    case legacy(String)

    func text(check: ComputerHealthEventCheck, state: ComputerHealthCheckState) -> String {
        switch self {
        case .status:
            let prefix: String = switch check {
            case .disk: L10n.text("磁盘自检：", "Disk Self Check: ")
            case .stability: L10n.text("系统稳定性：", "System Stability: ")
            case .backup: L10n.text("备份状态：", "Backup State: ")
            default: check.title + L10n.text("：", ": ")
            }
            return prefix + state.title(for: check)
        case .availableBytes(let bytes): return ByteFormat.storageString(bytes)
        case .batteryMaximumCapacity(let percent): return L10n.text("最大容量 \(percent)%", "Maximum Capacity \(percent)%")
        case .security(let evidence):
            guard let securityCheck = check.securityCheck else { return state.title(for: check) }
            return evidence.text(check: securityCheck, state: state.protectionState)
        case .legacy(let text): return text
        }
    }

    /// Only free text needs a bound; structured cases are fixed size.
    func bounded(to limit: Int) -> Self {
        func clip(_ text: String) -> String {
            String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
        }
        switch self {
        case .legacy(let text): return .legacy(clip(text))
        case .security(.legacy(let text)): return .security(.legacy(clip(text)))
        default: return self
        }
    }

    var freeTextLength: Int {
        switch self {
        case .legacy(let text), .security(.legacy(let text)): text.count
        default: 0
        }
    }
}

private enum ComputerHealthEventCodingKeys: String, CodingKey {
    case id, recordedAt, check, state, oldState, newState, evidence, evidenceSummary
}

struct ComputerHealthCheckObservation: Codable, Equatable, Sendable {
    let check: ComputerHealthEventCheck
    let state: ComputerHealthCheckState
    let evidence: ComputerHealthEventEvidence

    init(check: ComputerHealthEventCheck, state: ComputerHealthCheckState, evidence: ComputerHealthEventEvidence) {
        self.check = check
        self.state = state
        self.evidence = evidence
    }

    var evidenceSummary: String { evidence.text(check: check, state: state) }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ComputerHealthEventCodingKeys.self)
        check = try container.decode(ComputerHealthEventCheck.self, forKey: .check)
        state = try container.decode(ComputerHealthCheckState.self, forKey: .state)
        evidence = try container.decodeIfPresent(ComputerHealthEventEvidence.self, forKey: .evidence)
            ?? .legacy(try container.decode(String.self, forKey: .evidenceSummary))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ComputerHealthEventCodingKeys.self)
        try container.encode(check, forKey: .check)
        try container.encode(state, forKey: .state)
        try container.encode(evidence, forKey: .evidence)
    }

    /// Only structured status and numeric evidence enter the journal. No raw
    /// command output, volume names, diagnostic paths or user identifiers.
    static func observations(from snapshot: ComputerHealthSnapshot) -> [Self] {
        let diskState: ComputerHealthCheckState = switch snapshot.disk.smartStatus {
        case .verified: snapshot.disk.availability.hasUsableData ? .normal : .unreadable
        case .failing: .warning
        case .unsupported: .notApplicable
        case .unavailable: .unreadable
        }
        let capacityState = ComputerHealthCheckState(status: snapshot.capacity.status)
        var values = [
            Self(check: .disk, state: diskState, evidence: .status),
            Self(check: .capacity, state: capacityState, evidence:
                snapshot.capacity.availableForImportantUsageBytes.map(ComputerHealthEventEvidence.availableBytes) ?? .status),
            Self(check: .stability, state: .init(status: snapshot.stability.status), evidence: .status),
            Self(check: .backup, state: .init(status: snapshot.backup.status), evidence: .status)
        ]
        let batteryState: ComputerHealthCheckState = switch snapshot.batteryEvidence {
        case .notPresent: .notApplicable
        case .failed: .unreadable
        case .present(let battery): .init(status: battery.status)
        }
        values.append(Self(check: .battery, state: batteryState, evidence:
            snapshot.battery?.maximumCapacityPercent.map(ComputerHealthEventEvidence.batteryMaximumCapacity) ?? .status))
        for check in ComputerHealthEventCheck.allCases {
            guard let securityCheck = check.securityCheck,
                  let finding = snapshot.security?.findings.first(where: { $0.check == securityCheck }) else { continue }
            values.append(Self(check: check, state: .init(protection: finding.state), evidence: .security(finding.evidence)))
        }
        return values
    }
}

struct ComputerHealthChangeEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let check: ComputerHealthEventCheck
    let oldState: ComputerHealthCheckState
    let newState: ComputerHealthCheckState
    let evidence: ComputerHealthEventEvidence

    init(id: UUID, recordedAt: Date, check: ComputerHealthEventCheck, oldState: ComputerHealthCheckState,
         newState: ComputerHealthCheckState, evidence: ComputerHealthEventEvidence) {
        self.id = id
        self.recordedAt = recordedAt
        self.check = check
        self.oldState = oldState
        self.newState = newState
        self.evidence = evidence
    }

    /// Fixture/legacy convenience: free text is kept verbatim.
    init(id: UUID, recordedAt: Date, check: ComputerHealthEventCheck, oldState: ComputerHealthCheckState,
         newState: ComputerHealthCheckState, evidenceSummary: String) {
        self.init(id: id, recordedAt: recordedAt, check: check, oldState: oldState, newState: newState,
            evidence: .legacy(evidenceSummary))
    }

    var evidenceSummary: String { evidence.text(check: check, state: newState) }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ComputerHealthEventCodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        check = try container.decode(ComputerHealthEventCheck.self, forKey: .check)
        oldState = try container.decode(ComputerHealthCheckState.self, forKey: .oldState)
        newState = try container.decode(ComputerHealthCheckState.self, forKey: .newState)
        evidence = try container.decodeIfPresent(ComputerHealthEventEvidence.self, forKey: .evidence)
            ?? .legacy(try container.decode(String.self, forKey: .evidenceSummary))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ComputerHealthEventCodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(check, forKey: .check)
        try container.encode(oldState, forKey: .oldState)
        try container.encode(newState, forKey: .newState)
        try container.encode(evidence, forKey: .evidence)
    }
}

/// Outcome of one journal update.
struct ComputerHealthEventRecording: Equatable, Sendable {
    let events: [ComputerHealthChangeEvent]
    /// An unreadable or unknown-version journal was renamed aside
    /// (`.corrupt-<time>`) and a new baseline was started.
    var recoveredUnrecognizedJournal = false
}
