import Foundation

/// Prefer the live internal-battery capability to a slow/cached health scan.
/// Unknown remains unknown; an AC connection is not proof of battery presence.
enum MiniWindowBatteryPolicy {
    static func resolve(live: InternalBatteryAvailability,
                        healthSaysAbsent: Bool,
                        hasPowerSnapshot: Bool,
                        hasElectricalBatteryData: Bool,
                        hasHealthSnapshot: Bool) -> InternalBatteryAvailability {
        switch live {
        case .present: return .present
        case .absent: return .absent
        case .unknown:
            if healthSaysAbsent { return .absent }
            return hasPowerSnapshot || hasElectricalBatteryData || hasHealthSnapshot ? .present : .unknown
        }
    }
}
