// D153: the app's entry to the ported StatusMappings its VoiceOver value reads,
// so the bar and step thresholds stay Status Trio's single copy.

public enum CombinedStatusIconMappings {
    /// Wi-Fi bars for an RSSI: −60 dBm and up three, −78…−61 two, −88…−79 one.
    public static func wifiBars(rssi: Int?) -> Int {
        StatusMappings.wifiBars(rssi: rssi)
    }

    /// Volume steps (0–4) for a scalar; nil without a scalar.
    public static func volumeSteps(scalar: Double?, isMuted: Bool) -> Int? {
        StatusMappings.volumeSteps(scalar: scalar, isMuted: isMuted)
    }
}
