import AppKit

enum MenuBarWiFiSignalState: Equatable, Sendable {
    case connected(rssi: Int)
    case disconnected
    case off
    case unknown

    static func resolve(rssi: Int, serviceActive: Bool, hasChannel: Bool) -> Self {
        if (-127 ... -1).contains(rssi) { return .connected(rssi: rssi) }
        if rssi == 0, !serviceActive, !hasChannel { return .disconnected }
        return .unknown
    }

    var level: Int? {
        guard case let .connected(rssi) = self else { return nil }
        if rssi >= -55 { return 3 }
        if rssi >= -67 { return 2 }
        if rssi >= -80 { return 1 }
        return 0
    }

    var summary: String {
        switch self {
        case let .connected(rssi): "Wi-Fi \(rssi) dBm"
        case .disconnected: L10n.text("Wi-Fi 未连接", "Wi-Fi disconnected")
        case .off: L10n.text("Wi-Fi 已关闭", "Wi-Fi off")
        case .unknown: L10n.text("Wi-Fi 强度未知", "Wi-Fi signal unavailable")
        }
    }
}

struct MenuBarWiFiStatusSnapshot: Equatable, Sendable {
    let sampledAt: Date
    let state: MenuBarWiFiSignalState
}

/// Runtime-only input; the persistent history and existing display modes keep
/// their original schemas. Missing readings remain missing rather than zero.
struct MenuBarDeviceStatusSnapshot: Equatable, Sendable {
    let batteryAvailability: InternalBatteryAvailability
    let batteryPercent: Int?
    let isCharging: Bool
    let isChargedOnAC: Bool
    let memoryPercent: Int?
    let wiFi: MenuBarWiFiSignalState
    let isPaused: Bool
    let sampledAt: Date?

    init(
        batteryPercent: Int?,
        isCharging: Bool?,
        memoryUsedRatio: Double?,
        wiFi: MenuBarWiFiSignalState,
        isPaused: Bool = false,
        sampledAt: Date? = nil,
        isFullyCharged: Bool = false,
        isConnectedToAC: Bool = false,
        batteryAvailability: InternalBatteryAvailability = .unknown
    ) {
        self.batteryAvailability = batteryAvailability
        self.batteryPercent = batteryPercent.flatMap { (0...100).contains($0) ? $0 : nil }
        self.isCharging = isCharging == true && self.batteryPercent != nil
        self.isChargedOnAC = isFullyCharged && isConnectedToAC && self.batteryPercent != nil
        self.memoryPercent = memoryUsedRatio.flatMap {
            $0.isFinite && (0...1).contains($0) ? Int(($0 * 100).rounded()) : nil
        }
        self.wiFi = wiFi
        self.isPaused = isPaused
        self.sampledAt = sampledAt
    }

    static let empty = Self(
        batteryPercent: nil, isCharging: nil, memoryUsedRatio: nil, wiFi: .unknown
    )

    var showsMemoryRing: Bool { batteryAvailability == .absent }
    var ringPercent: Int? { showsMemoryRing ? memoryPercent : batteryPercent }

    enum BatteryTint: Equatable { case full, charging, normal, low, critical }

    var batteryTint: BatteryTint {
        if isChargedOnAC { return .full }
        if isCharging { return .charging }
        guard let batteryPercent else { return .normal }
        if batteryPercent < 20 { return .critical }
        if batteryPercent < 50 { return .low }
        return .normal
    }

    var batteryText: String { batteryPercent.map { "\($0)%" } ?? "—" }
    var memoryText: String { memoryPercent.map { "\($0)%" } ?? "—" }

    /// Includes every visible state, so independent power/radio updates cannot
    /// be suppressed by the primary CPU/memory monitor's rendering cache.
    var accessibilitySummary: String {
        let charging = isChargedOnAC ? L10n.text("，已充满", ", fully charged")
            : isCharging ? L10n.text("，充电中", ", charging") : ""
        let paused = isPaused ? L10n.text("，已暂停", ", paused") : ""
        if showsMemoryRing {
            return L10n.text(
                "内存占用 \(memoryText)，上半圈：内存，\(wiFi.summary)\(paused)",
                "Memory usage \(memoryText), upper ring: memory, \(wiFi.summary)\(paused)"
            )
        }
        return L10n.text(
            "电量 \(batteryText)\(charging)，内存占用 \(memoryText)，\(wiFi.summary)\(paused)",
            "Battery \(batteryText)\(charging), memory usage \(memoryText), \(wiFi.summary)\(paused)"
        )
    }
}

@MainActor
enum MenuBarDeviceStatusDrawing {
    static let size = NSSize(width: 28, height: 24)
    private static let ringStart: CGFloat = 210
    private static let ringSweep: CGFloat = 240

    static func image(
        for snapshot: MenuBarDeviceStatusSnapshot,
        appearance: NSAppearance? = nil, highlighted: Bool = false
    ) -> NSImage {
        let image = NSImage(size: size)
        let appearance = appearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            draw(snapshot, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                 highlighted: highlighted)
            image.unlockFocus()
        }
        // Preserve the battery's semantic color; the digits and dots resolve
        // against the status button's appearance, independently of the window.
        image.isTemplate = false
        return image
    }

    static func draw(_ snapshot: MenuBarDeviceStatusSnapshot, dark: Bool, highlighted: Bool) {
        // macOS highlights a status item with a translucent background, not
        // the blue selection used inside menus. Keep the appearance's ink.
        let foreground: NSColor = dark ? .white : .black
        let center = NSPoint(x: 14, y: 12)
        let memoryColor = NSColor(srgbRed: dark ? 0.36 : 0.1, green: dark ? 0.69 : 0.46,
                                  blue: dark ? 1 : 0.86, alpha: 1)
        let track = snapshot.showsMemoryRing
            ? memoryColor.withAlphaComponent(dark ? 0.25 : 0.2)
            : NSColor(srgbRed: 0.98, green: 0.88, blue: 0.55, alpha: dark ? 0.32 : 0.55)
        arc(center: center, radius: 9.4, end: ringStart - ringSweep, color: track)
        if let percent = snapshot.ringPercent, percent > 0 {
            arc(center: center, radius: 9.4, end: ringStart - ringSweep * CGFloat(percent) / 100,
                color: snapshot.showsMemoryRing ? memoryColor : batteryColor(snapshot.batteryTint, dark: dark))
        }

        let value = snapshot.memoryPercent.map(String.init) ?? "—"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
            .foregroundColor: foreground
        ]
        let textSize = (value as NSString).size(withAttributes: attributes)
        (value as NSString).draw(at: NSPoint(x: (size.width - textSize.width) / 2,
                                           y: 12 - textSize.height / 2),
                                 withAttributes: attributes)

        for index in 0..<3 {
            let angle = CGFloat(250 + index * 20) * .pi / 180
            let point = NSPoint(x: center.x + 9.3 * cos(angle), y: center.y + 9.3 * sin(angle))
            let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 1.25, y: point.y - 1.25,
                                                 width: 2.5, height: 2.5))
            if snapshot.wiFi == .unknown, index == 1 {
                let question: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 5.5, weight: .bold), .foregroundColor: foreground
                ]
                let qSize = ("?" as NSString).size(withAttributes: question)
                ("?" as NSString).draw(at: NSPoint(x: point.x - qSize.width / 2,
                                                 y: point.y - qSize.height / 2), withAttributes: question)
            } else if snapshot.wiFi == .disconnected || snapshot.wiFi == .unknown {
                foreground.withAlphaComponent(0.45).setStroke()
                dot.lineWidth = 0.65
                dot.stroke()
            } else {
                foreground.withAlphaComponent(index < (snapshot.wiFi.level ?? 0) ? 1 : 0.22).setFill()
                dot.fill()
            }
        }
        if snapshot.wiFi == .off {
            foreground.setStroke()
            let slash = NSBezierPath()
            slash.lineWidth = 0.9
            slash.lineCapStyle = .round
            slash.move(to: NSPoint(x: 10, y: 1.4))
            slash.line(to: NSPoint(x: 18, y: 5.7))
            slash.stroke()
        }
    }

    static func batteryColor(_ tint: MenuBarDeviceStatusSnapshot.BatteryTint, dark: Bool) -> NSColor {
        switch tint {
        case .full, .charging: NSColor(srgbRed: dark ? 0.27 : 0.12, green: dark ? 0.8 : 0.61, blue: 0.32, alpha: 1)
        case .normal: NSColor(srgbRed: dark ? 1 : 0.82, green: dark ? 0.82 : 0.62, blue: 0.02, alpha: 1)
        case .low: NSColor(srgbRed: 0.9, green: 0.38, blue: 0.03, alpha: 1)
        case .critical: NSColor(srgbRed: 0.9, green: 0.19, blue: 0.22, alpha: 1)
        }
    }

    private static func arc(center: NSPoint, radius: CGFloat, end: CGFloat, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.appendArc(withCenter: center, radius: radius,
                       startAngle: ringStart, endAngle: end, clockwise: true)
        path.stroke()
    }
}
