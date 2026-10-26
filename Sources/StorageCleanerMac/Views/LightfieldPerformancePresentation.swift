import Foundation

/// Display-only adapters. They never change scan scopes, capabilities or data.
enum LightfieldPerformancePresentation {
    static func currentEnergySource(_ apps: [EnergyImpactApp]) -> EnergyMetricSource {
        let sources = Set(apps.map { $0.currentEvidence.source })
        guard !sources.isEmpty, !sources.contains(.unknown) else { return .unknown }
        return sources.count == 1 ? sources.first ?? .unknown : .mixed
    }

    static func memoryOutcome(_ status: MemoryOptimizationStatus) -> String {
        switch status {
        case .completed: L10n.text("已完成并验证", "Completed and Verified")
        case .partial: L10n.text("部分完成", "Partially Completed")
        case .cancelled: L10n.text("已取消", "Cancelled")
        case .verificationFailed: L10n.text("验证未通过", "Verification Failed")
        case .notNeeded: L10n.text("无需处理", "No Action Needed")
        case .restricted: L10n.text("操作受限", "Restricted")
        case .timedOut: L10n.text("操作超时", "Timed Out")
        case .unavailable: L10n.text("暂不可用", "Unavailable")
        }
    }
    static func memoryGroups(_ snapshot: MemorySnapshot, scope: Int) -> [MemoryAppUsage] {
        let groups = snapshot.appsByResidentUsage
        switch scope {
        case 1: return groups.filter { $0.canQuit && $0.bundlePath?.hasSuffix(".app") == true }
        case 2: return groups.filter { $0.bundlePath == nil }
        default: return groups
        }
    }

    static func children(of app: MemoryAppUsage, in snapshot: MemorySnapshot) -> [MemoryProcess] {
        let ids = Set(app.processIDs)
        return snapshot.processesByResidentUsage.filter { ids.contains($0.id) }
    }

    /// A helper executable has a useful role; never present a PID as its name.
    /// Unknown roles retain their real executable name instead of guessing.
    static func processName(name: String, path: String, application: String) -> String {
        let basename = path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent
        let executable = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? basename : name
        // The enclosing application/folder can contain “Helper” or “GPU”.
        // Infer a role only from the captured name and executable basename.
        let lower = (executable + " " + basename).lowercased()
        let role: String?
        if lower.contains("renderer") { role = L10n.text("网页渲染", "Web Renderer") }
        else if lower.contains("gpu") { role = L10n.text("图形处理", "Graphics") }
        else if lower.contains("network") { role = L10n.text("网络服务", "Network Service") }
        else if lower.contains("helper") { role = L10n.text("辅助服务", "Helper Service") }
        else { role = nil }
        if let role { return application + " · " + role }
        return executable.isEmpty ? L10n.text("名称不可用", "Name Unavailable") : executable
    }

    static func processHelp(id: Int32, path: String) -> String {
        L10n.text("进程号 \(id)", "Process ID \(id)") + (path.isEmpty ? "" : "\n" + path)
    }

    static func startupScopeMetadata(items: [StartupItemsDomain.Item], kinds: Set<StartupItemsDomain.ItemKind>) -> String {
        guard !items.isEmpty else { return L10n.text("固定检查范围", "Included in Every Check") }
        let matches = items.filter { kinds.contains($0.kind) }
        let manageable = matches.filter { $0.manageability == .directlyManageable }.count
        return L10n.text("\(ByteFormat.count(matches.count)) 项 · 可管理 \(manageable)", "\(ByteFormat.count(matches.count)) items · \(manageable) manageable")
    }
}
