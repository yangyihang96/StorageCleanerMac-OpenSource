import Foundation

/// An allowlisted support payload, not a filtered copy of logs or preferences.
/// Construction consumes existing snapshots and never loads files or samples hardware.
struct RedactedSupportSnapshot: Codable, Equatable, Sendable {
    let schema: Int
    let appVersion: String?
    let appBuild: String?
    let channel: String
    let macOSVersion: String
    let architecture: String
    let loadedOperationCount: Int
    let operationStates: [String: Int]
    let scope: String

    init(runtime: AppRuntimeInfo, systemVersion: OperatingSystemVersion,
         reports: [CleanupReportIndex]) {
        schema = 1
        appVersion = Self.validated(runtime.version, pattern: #"^[0-9]{1,3}(\.[0-9]{1,3}){1,2}$"#)
        appBuild = Self.validated(runtime.build, pattern: #"^[0-9]{1,20}$"#)
        channel = runtime.buildInfo?.isBeta == true ? "beta" : "standard-or-unknown"
        macOSVersion = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
            .map { String(min(999, max(0, $0))) }.joined(separator: ".")
#if arch(arm64)
        architecture = "arm64"
#elseif arch(x86_64)
        architecture = "x86_64"
#else
        architecture = "unknown"
#endif
        // Only bounded, already-loaded summaries. No IDs, paths, names, error
        // details or timestamps can enter this schema.
        let bounded = reports.prefix(100)
        loadedOperationCount = bounded.count
        operationStates = bounded.reduce(into: [:]) { counts, report in
            let key = report.presentation?.state.rawValue ?? "unavailable"
            counts[key, default: 0] += 1
        }
        scope = "up-to-100-already-loaded-operation-summaries"
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private static func validated(_ value: String?, pattern: String) -> String? {
        guard let value, value.utf8.count <= 32,
              value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }
}
