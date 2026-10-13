import Foundation
import FanControlShared
import IOKit

enum MacMiniHardwareCapabilities {
    // The device capability is fixed for this process. Read-only registry access
    // happens lazily, after the view has rejected fixtures and absent batteries.
    private static let hasClamshell: Bool = {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return false }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return true }
        return (value as? NSNumber).map { [0.0, 1.0].contains($0.doubleValue) } ?? false
    }()

    @MainActor
    static func shouldOffer(hasInternalBattery: Bool, isDataOnlyFixture: Bool) -> Bool {
        guard hasInternalBattery, !isDataOnlyFixture, BatteryChargeLimitAccess.allowsLiveAccess else { return false }
        return MacMiniModeAvailability.shouldOffer(hasInternalBattery: hasInternalBattery, hasClamshell: hasClamshell)
    }
}
