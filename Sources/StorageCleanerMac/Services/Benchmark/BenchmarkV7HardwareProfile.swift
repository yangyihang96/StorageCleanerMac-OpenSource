import Foundation
import SystemConfiguration

/// Non-unique hardware details shown with a V7 benchmark session.
///
/// These fields intentionally live outside the frozen V6 environment model:
/// adding them to the old model would change its source fingerprint and its
/// calibration contract. Optional fields also keep early V7 JSON decodable.
struct BenchmarkV7HardwareProfile: Equatable, Codable, Sendable {
    let computerName: String?
    let computerModel: String?
    let modelIdentifier: String?
    let gpuCoreCount: Int?
    let storageModel: String?

    init(
        computerName: String? = nil,
        computerModel: String? = nil,
        modelIdentifier: String? = nil,
        gpuCoreCount: Int? = nil,
        storageModel: String? = nil
    ) {
        self.computerName = computerName
        self.computerModel = computerModel
        self.modelIdentifier = modelIdentifier
        self.gpuCoreCount = gpuCoreCount
        self.storageModel = storageModel
    }
}

protocol BenchmarkV7HardwareProfileProviding: Sendable {
    func capture() -> BenchmarkV7HardwareProfile?
}

struct SystemBenchmarkV7HardwareProfileProvider: BenchmarkV7HardwareProfileProviding {
    func capture() -> BenchmarkV7HardwareProfile? {
        BenchmarkV7HardwareProfileCollector.capture()
    }
}

enum BenchmarkV7HardwareProfileCollector {
    static let systemProfilerExecutable = "/usr/sbin/system_profiler"
    static let systemProfilerArguments = [
        "-json",
        "-detailLevel", "mini",
        "-timeout", "1",
        "SPHardwareDataType",
        "SPDisplaysDataType",
        "SPNVMeDataType",
        "SPStorageDataType"
    ]
    static let systemProfilerTimeout: TimeInterval = 1.5
    private static let cache = Cache()

    static func capture() -> BenchmarkV7HardwareProfile? {
        cache.value()
    }

    /// Parses only stable, non-unique fields. Serial numbers, UUIDs, model
    /// numbers and paths are deliberately ignored before a result can persist.
    static func parseSystemProfilerJSON(
        _ data: Data,
        computerName: String? = nil
    ) -> BenchmarkV7HardwareProfile? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return nil
        }

        let hardware = firstDictionary(in: root["SPHardwareDataType"])
        let displays = dictionaries(in: root["SPDisplaysDataType"])
        let nvmeControllers = dictionaries(in: root["SPNVMeDataType"])
        let storageVolumes = dictionaries(in: root["SPStorageDataType"])
        let gpuCoreCount = displays
            .compactMap { positiveInt($0["sppci_cores"]) }
            .max()
        let storageModel = nvmeControllers
            .flatMap { dictionaries(in: $0["_items"]) }
            .compactMap { profileString($0["device_model"]) ?? profileString($0["_name"]) }
            .first
            ?? storageVolumes
                .compactMap { $0["physical_drive"] as? [String: Any] }
                .compactMap { profileString($0["device_name"]) }
                .first

        let profile = BenchmarkV7HardwareProfile(
            computerName: profileString(computerName),
            computerModel: profileString(hardware?["machine_name"]),
            modelIdentifier: profileString(hardware?["machine_model"]),
            gpuCoreCount: gpuCoreCount,
            storageModel: storageModel
        )
        return profile.computerName != nil
            || profile.computerModel != nil
            || profile.modelIdentifier != nil
            || profile.gpuCoreCount != nil
            || profile.storageModel != nil
            ? profile
            : nil
    }

    private static func read() -> BenchmarkV7HardwareProfile? {
        guard FileManager.default.isExecutableFile(atPath: systemProfilerExecutable),
              let result = try? Shell.run(
                  systemProfilerExecutable,
                  systemProfilerArguments,
                  timeout: systemProfilerTimeout,
                  outputByteLimit: 1_048_576
              ),
              result.terminationStatus == 0 else {
            return nil
        }
        return parseSystemProfilerJSON(
            Data(result.standardOutput.utf8),
            computerName: currentComputerName()
        )
    }

    private static func currentComputerName() -> String? {
        profileString(SCDynamicStoreCopyComputerName(nil, nil) as String?)
    }

    private static func dictionaries(in value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func firstDictionary(in value: Any?) -> [String: Any]? {
        dictionaries(in: value).first
    }

    private static func profileString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        let number: Int?
        if let value = value as? NSNumber {
            number = value.intValue
        } else if let value = value as? String {
            number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            number = nil
        }
        guard let number, number > 0 else { return nil }
        return number
    }

    private final class Cache: @unchecked Sendable {
        private static let refreshInterval: TimeInterval = 300
        private let lock = NSLock()
        private var cached: BenchmarkV7HardwareProfile?
        private var validUntil = Date.distantPast

        func value(now: Date = Date()) -> BenchmarkV7HardwareProfile? {
            lock.lock()
            defer { lock.unlock() }

            if now < validUntil {
                return cached
            }
            // The command has a hard timeout and output limit. Holding this
            // lock ensures concurrent benchmark starts share one bounded read.
            cached = BenchmarkV7HardwareProfileCollector.read()
            validUntil = now.addingTimeInterval(Self.refreshInterval)
            return cached
        }
    }
}
