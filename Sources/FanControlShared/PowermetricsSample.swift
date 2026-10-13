import CoreFoundation
import Foundation

/// A deliberately small reply. No process names, paths, raw plist or stderr.
public struct PowermetricsSample: Codable, Equatable, Sendable {
    public struct Timing: Codable, Equatable, Sendable {
        public enum Quality: String, Codable, Sendable {
            case helperMeasured, requestBracketOnly, legacyUntimed
        }
        public let sampleID: String
        public let helperBootID: String
        public let clockDomain: String
        public let measurementStartMonotonicNs: UInt64?
        public let measurementEndMonotonicNs: UInt64?
        public let timestampQuality: Quality
        /// Child lifecycle bounds are diagnostic, never the measurement interval.
        public var helperProcessStartMonotonicNs: UInt64? = nil
        public var helperProcessEndMonotonicNs: UInt64? = nil
        public var timestampSource: String? = nil

        public static let maximumTimestampSourceBytes = 64
        private static func supportsTimestampSource(_ source: String) -> Bool {
            source.utf8.count <= maximumTimestampSourceBytes
                && ["nativeTimestampStart+elapsed_ns", "nativeTimestampEnd+elapsed_ns"].contains(source)
        }

        private enum CodingKeys: String, CodingKey {
            case sampleID, helperBootID, clockDomain, measurementStartMonotonicNs, measurementEndMonotonicNs
            case timestampQuality, helperProcessStartMonotonicNs, helperProcessEndMonotonicNs, timestampSource
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sampleID = try c.decode(String.self, forKey: .sampleID)
            helperBootID = try c.decode(String.self, forKey: .helperBootID)
            clockDomain = try c.decode(String.self, forKey: .clockDomain)
            helperProcessStartMonotonicNs = try c.decodeIfPresent(UInt64.self, forKey: .helperProcessStartMonotonicNs)
            helperProcessEndMonotonicNs = try c.decodeIfPresent(UInt64.self, forKey: .helperProcessEndMonotonicNs)
            let hasSource = try c.contains(.timestampSource) && !c.decodeNil(forKey: .timestampSource)
            let source = try? c.decode(String.self, forKey: .timestampSource)
            if hasSource && !(source.map(Self.supportsTimestampSource) ?? false) {
                // Unknown, oversized or wrong-typed provenance is diagnostic
                // only; neither retain the untrusted string nor its interval.
                timestampQuality = .requestBracketOnly
                measurementStartMonotonicNs = nil
                measurementEndMonotonicNs = nil
                timestampSource = nil
            } else {
                timestampQuality = try c.decode(Quality.self, forKey: .timestampQuality)
                measurementStartMonotonicNs = try c.decodeIfPresent(UInt64.self, forKey: .measurementStartMonotonicNs)
                measurementEndMonotonicNs = try c.decodeIfPresent(UInt64.self, forKey: .measurementEndMonotonicNs)
                timestampSource = source
            }
        }

        public init(sampleID: String, helperBootID: String, clockDomain: String,
                    measurementStartMonotonicNs: UInt64? = nil, measurementEndMonotonicNs: UInt64? = nil,
                    timestampQuality: Quality) {
            self.sampleID = sampleID; self.helperBootID = helperBootID; self.clockDomain = clockDomain
            self.measurementStartMonotonicNs = measurementStartMonotonicNs
            self.measurementEndMonotonicNs = measurementEndMonotonicNs
            self.timestampQuality = timestampQuality
        }

        public var isWellFormed: Bool {
            UUID(uuidString: sampleID) != nil && UUID(uuidString: helperBootID) != nil
                && !clockDomain.isEmpty && clockDomain.utf8.count <= 64
                && clockDomain.utf8.allSatisfy {
                    $0 == 45 || $0 == 46 || $0 == 95 || (48...57).contains($0)
                        || (65...90).contains($0) || (97...122).contains($0)
                }
                && (timestampSource.map(Self.supportsTimestampSource) ?? true)
        }
    }

    public struct ClusterFrequency: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case performance, efficiency }
        public let name: String
        public let kind: Kind
        public let megahertz: Double

        public init(name: String, kind: Kind, megahertz: Double) {
            self.name = name
            self.kind = kind
            self.megahertz = megahertz
        }
    }

    public let cpuMilliwatts: Double?
    public let gpuMilliwatts: Double?
    public let aneMilliwatts: Double?
    public let clusters: [ClusterFrequency]
    public let gpuMegahertz: Double?
    public let durationSeconds: Double
    /// Optional on the wire so an existing v4 helper remains decodable.
    public let timing: Timing?

    public init(cpuMilliwatts: Double?, gpuMilliwatts: Double?, aneMilliwatts: Double?,
                clusters: [ClusterFrequency], gpuMegahertz: Double?, durationSeconds: Double, timing: Timing? = nil) {
        self.cpuMilliwatts = cpuMilliwatts
        self.gpuMilliwatts = gpuMilliwatts
        self.aneMilliwatts = aneMilliwatts
        self.clusters = clusters
        self.gpuMegahertz = gpuMegahertz
        self.durationSeconds = durationSeconds
        self.timing = timing
    }

    public func withTiming(_ timing: Timing) -> Self {
        Self(cpuMilliwatts: cpuMilliwatts, gpuMilliwatts: gpuMilliwatts, aneMilliwatts: aneMilliwatts,
             clusters: clusters, gpuMegahertz: gpuMegahertz, durationSeconds: durationSeconds, timing: timing)
    }

    public var isValid: Bool {
        let powers = [cpuMilliwatts, gpuMilliwatts, aneMilliwatts].compactMap { $0 }
        return durationSeconds.isFinite && (0.05...5).contains(durationSeconds)
            && (timing?.isWellFormed ?? true)
            && powers.allSatisfy { $0.isFinite && (0...1_000_000).contains($0) }
            && (gpuMegahertz.map { $0.isFinite && (0...10_000).contains($0) } ?? true)
            && clusters.count <= 16 && Set(clusters.map(\.name)).count == clusters.count
            && clusters.allSatisfy {
                PowermetricsPlistParser.clusterKind($0.name) == $0.kind
                    && $0.megahertz.isFinite && (0...10_000).contains($0.megahertz)
            }
            && (!powers.isEmpty || !clusters.isEmpty || gpuMegahertz != nil)
    }
}

public enum PowermetricsFailure: String, Codable, Error, Sendable {
    case invalidRequest, unauthorized, unavailable, throttled, busy
    case launchFailed, commandFailed, timedOut, outputTooLarge, invalidOutput
}

public enum PowermetricsResult: Codable, Equatable, Sendable {
    case sample(PowermetricsSample)
    case failure(PowermetricsFailure)
}

/// Strict envelope: the caller cannot pass flags, paths, a timeout, or a rate.
public struct PowermetricsSamplingRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case samplePowerMetrics }
    public let protocolVersion: Int
    public let operation: Operation
    public init(protocolVersion: Int = HardwareControlProtocol.currentVersion) {
        self.protocolVersion = protocolVersion
        operation = .samplePowerMetrics
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 512,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["protocolVersion", "operation"] else {
            throw PowermetricsFailure.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard HardwareControlProtocol.accepts(request.protocolVersion) else {
            throw PowermetricsFailure.invalidRequest
        }
        return request
    }
}

public enum PowermetricsClientPolicy {
    public static let teamIdentifier = "T9GZL52H8R"

    /// Inputs must be derived from the audit-token code object, never JSON/PID.
    /// Paths are compared as canonical path strings: URL equality would depend
    /// on whether Foundation added a directory slash after a filesystem probe.
    public static func permits(identifier: String, team: String, executableURL: URL,
                               helperApplicationURL: URL?) -> Bool {
        let application = StorageCleanerBuildIdentity.installedApplicationPath
        let executable = StorageCleanerBuildIdentity.installedExecutablePath
        guard executableURL.isFileURL, let helperApplicationURL, helperApplicationURL.isFileURL else { return false }
        return identifier == StorageCleanerBuildIdentity.appBundleIdentifier
            && team == teamIdentifier
            && executableURL.standardizedFileURL.path == executable
            && executableURL.resolvingSymlinksInPath().path == executable
            && helperApplicationURL.standardizedFileURL.path == application
            && helperApplicationURL.resolvingSymlinksInPath().path == application
    }
}

public enum PowermetricsPlistParser {
    public static let maximumOutputBytes = 512 * 1_024

    /// Native plist output is NUL separated. A one-sample command must yield
    /// exactly one document; never join documents or parse text-mode output.
    public static func parse(_ data: Data, measurementContext: PowermetricsMeasurementContext? = nil) throws -> PowermetricsSample {
        guard !data.isEmpty, data.count <= maximumOutputBytes else {
            throw data.isEmpty ? PowermetricsFailure.invalidOutput : .outputTooLarge
        }
        let frames = data.split(separator: 0).filter { frame in
            frame.contains { ![9, 10, 13, 32].contains($0) }
        }
        guard frames.count == 1,
              let root = try PropertyListSerialization.propertyList(
                from: Data(frames[0]), options: [], format: nil) as? [String: Any],
              let elapsed = number(root["elapsed_ns"]),
              (50_000_000...5_000_000_000).contains(elapsed) else {
            throw PowermetricsFailure.invalidOutput
        }
        let seconds = elapsed / 1_000_000_000
        let processor = root["processor"] as? [String: Any] ?? [:]
        let gpu = root["gpu"] as? [String: Any] ?? [:]
        let clusters = (processor["clusters"] as? [[String: Any]] ?? [])
        guard clusters.count <= 16 else { throw PowermetricsFailure.invalidOutput }
        var frequencies: [PowermetricsSample.ClusterFrequency] = []
        for cluster in clusters {
            guard let name = cluster["name"] as? String, let kind = clusterKind(name),
                  let mhz = frequency(cluster, nativeGPU: false) else { continue }
            frequencies.append(.init(name: name, kind: kind, megahertz: mhz))
        }
        let sample = PowermetricsSample(
            cpuMilliwatts: power(processor, prefix: "cpu", seconds: seconds),
            gpuMilliwatts: power(processor, prefix: "gpu", seconds: seconds),
            aneMilliwatts: power(processor, prefix: "ane", seconds: seconds),
            clusters: frequencies,
            gpuMegahertz: frequency(gpu, nativeGPU: true), durationSeconds: seconds
        )
        guard sample.isValid else { throw PowermetricsFailure.invalidOutput }
        guard let measurementContext else { return sample }
        return sample.withTiming(measurementContext.timing(root: root))
    }

    static func clusterKind(_ name: String) -> PowermetricsSample.ClusterFrequency.Kind? {
        // Preserve the original identity, including an Ultra die prefix. MCPU
        // is a performance tier, never an efficiency-core alias.
        guard name.utf8.count <= 32 else { return nil }
        var cluster = name[...]
        if cluster.hasPrefix("DIE_") {
            cluster = cluster.dropFirst(4)
            let digits = cluster.prefix { $0 >= "0" && $0 <= "9" }
            guard !digits.isEmpty, digits.count <= 2 else { return nil }
            cluster = cluster.dropFirst(digits.count)
            guard cluster.first == "_" || cluster.first == " " else { return nil }
            cluster = cluster.dropFirst()
        }
        for (prefix, kind) in [("PCPU", PowermetricsSample.ClusterFrequency.Kind.performance),
                               ("MCPU", .performance), ("ECPU", .efficiency),
                               ("P", .performance), ("E", .efficiency)] {
            guard cluster.hasPrefix(prefix) else { continue }
            let suffix = cluster.dropFirst(prefix.count)
            guard suffix.count <= 3, suffix.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  prefix.count > 1 || !suffix.isEmpty else { return nil }
            return kind
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func power(_ object: [String: Any], prefix: String, seconds: Double) -> Double? {
        let watts: Double?
        if let raw = object[prefix + "_power"] {
            // Native *_power fields are mW. An explicit unknown unit is refused.
            guard let unit = unit(object, key: "power_unit", nativeDefault: "mW") else { return nil }
            let factor: Double? = unit == "mW" ? 1 : (unit == "W" ? 1_000 : nil)
            watts = number(raw).flatMap { value in factor.map { value * $0 } }
        } else {
            // Native *_energy fields are interval energy in mJ, not power.
            guard let unit = unit(object, key: "energy_unit", nativeDefault: "mJ") else { return nil }
            let factor: Double? = switch unit {
            case "mJ": 1; case "J": 1_000; case "uJ", "µJ", "μJ": 0.001; default: nil
            }
            watts = number(object[prefix + "_energy"]).flatMap { value in factor.map { value * $0 / seconds } }
        }
        return watts.flatMap { (0...1_000_000).contains($0) ? $0 : nil }
    }

    private static func unit(_ object: [String: Any], key: String, nativeDefault: String) -> String? {
        guard let raw = object[key] else { return nativeDefault }
        return raw as? String
    }

    private static func frequency(_ object: [String: Any], nativeGPU: Bool) -> Double? {
        let mhz: Double?
        if let raw = object["freq_mhz"] {
            mhz = number(raw)
        } else if let hz = number(object["freq_hz"]) {
            if let rawUnit = object["frequency_unit"] {
                guard let unit = rawUnit as? String else { return nil }
                mhz = unit == "Hz" ? hz / 1_000_000 : (unit == "MHz" ? hz : nil)
            } else {
                // Native CPU cluster freq_hz is Hz; the GPU plist field with
                // the same name historically reports MHz. Also accept GPU Hz
                // when it falls in the disjoint, physically plausible Hz range.
                if nativeGPU, hz > 10_000, hz < 1_000_000 { return nil }
                mhz = nativeGPU && hz <= 10_000 ? hz : hz / 1_000_000
            }
        } else { mhz = nil }
        return mhz.flatMap { (0...10_000).contains($0) ? $0 : nil }
    }
}
