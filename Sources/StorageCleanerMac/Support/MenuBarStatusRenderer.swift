import AppKit

@MainActor
enum MenuBarStatusRenderer {
    static let initialWidth: CGFloat = 54

    private static let height: CGFloat = 24
    private static let memoryIcon: NSImage? = statusSymbol("memorychip.fill")
    private static let cpuIcon: NSImage? = statusSymbol("cpu.fill")
    private static let temperatureIcon: NSImage? = statusSymbol("thermometer.medium")

    private static func statusSymbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    static func image(for snapshot: SystemMonitorSnapshot?) -> NSImage {
        let size = NSSize(width: initialWidth, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        drawIcon()
        drawMemoryUsage(memoryUsageText(for: snapshot))
        image.isTemplate = true
        return image
    }

    static func image(
        for snapshot: SystemMonitorSnapshot?,
        mode: MenuBarStatusDisplayMode,
        deviceStatus: MenuBarDeviceStatusSnapshot = .empty,
        appearance: NSAppearance? = nil, highlighted: Bool = false
    ) -> NSImage {
        switch mode {
        case .deviceStatus:
            return MenuBarDeviceStatusDrawing.image(for: deviceStatus, appearance: appearance, highlighted: highlighted)
        case .memory:
            return image(for: snapshot)
        case .cpu:
            return singleValueImage(
                icon: cpuIcon,
                text: displayValue(for: .cpuUsage, snapshot: snapshot)
            )
        case .temperature:
            return singleValueImage(
                icon: temperatureIcon,
                text: displayValue(for: .chipTemperature, snapshot: snapshot)
            )
        case .cpuAndMemory:
            return stackedTextImage(
                top: "C \(displayValue(for: .cpuUsage, snapshot: snapshot))",
                bottom: "M \(displayValue(for: .memoryUsage, snapshot: snapshot))"
            )
        case .network:
            let throughput = snapshot?.networkThroughput
            return stackedTextImage(
                top: "↓\(menuBarRate(throughput?.downBytesPerSecond))",
                bottom: "↑\(menuBarRate(throughput?.upBytesPerSecond))"
            )
        }
    }

    /// Icon plus one measured value, matching the reference memory layout but
    /// sized to the rendered text so wide values never clip.
    private static func singleValueImage(icon: NSImage?, text: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let textWidth = ceil((text as NSString).size(withAttributes: attributes).width)
        let width = max(40, 19 + textWidth + 3)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        icon?.draw(in: NSRect(x: 2, y: 5, width: 14, height: 14))
        (text as NSString).draw(
            in: NSRect(x: 19, y: 5, width: textWidth, height: 14),
            withAttributes: attributes
        )
        image.isTemplate = true
        return image
    }

    /// Two compact monospaced lines in the iStat dual-line style.
    private static func stackedTextImage(top: String, bottom: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let topWidth = ceil((top as NSString).size(withAttributes: attributes).width)
        let bottomWidth = ceil((bottom as NSString).size(withAttributes: attributes).width)
        let lineWidth = max(topWidth, bottomWidth)
        let width = max(34, lineWidth + 8)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        (top as NSString).draw(
            in: NSRect(x: 4, y: 12, width: lineWidth, height: 11),
            withAttributes: attributes
        )
        (bottom as NSString).draw(
            in: NSRect(x: 4, y: 1, width: lineWidth, height: 11),
            withAttributes: attributes
        )
        image.isTemplate = true
        return image
    }

    private static func menuBarRate(_ bytesPerSecond: Int64?) -> String {
        compactRate(bytesPerSecond).replacingOccurrences(of: "/s", with: "")
    }

    static func accessibilitySummary(for snapshot: SystemMonitorSnapshot?) -> String {
        let metrics = metricColumns(for: snapshot)
            .map { kind in
                "\(accessibilityLabel(for: kind)) \(displayValue(for: kind, snapshot: snapshot))"
            }
            .joined(separator: L10n.text("，", ", "))
        let throughput = snapshot?.networkThroughput
        let network = L10n.text(
            "上传 \(compactRate(throughput?.upBytesPerSecond))，下载 \(compactRate(throughput?.downBytesPerSecond))",
            "Upload \(compactRate(throughput?.upBytesPerSecond)), download \(compactRate(throughput?.downBytesPerSecond))"
        )
        return "\(metrics)，\(network)"
    }

    private static func metricColumns(for snapshot: SystemMonitorSnapshot?) -> [MenuBarMetricKind] {
        var columns: [MenuBarMetricKind] = [.cpuUsage]
        if shouldShow(.gpuUsage, snapshot: snapshot) {
            columns.append(.gpuUsage)
        }
        columns.append(.memoryUsage)
        if shouldShow(.chipTemperature, snapshot: snapshot) {
            columns.append(.chipTemperature)
        }
        if shouldShow(.fanSpeed, snapshot: snapshot) {
            columns.append(.fanSpeed)
        }
        return columns
    }

    private static func shouldShow(_ kind: MenuBarMetricKind, snapshot: SystemMonitorSnapshot?) -> Bool {
        guard let snapshot else { return true }
        return snapshot.metric(for: kind)?.isAvailable == true
    }

    private static func displayValue(
        for kind: MenuBarMetricKind,
        snapshot: SystemMonitorSnapshot?
    ) -> String {
        guard let metric = snapshot?.metric(for: kind), metric.isAvailable else {
            return "--"
        }
        return kind == .fanSpeed
            ? metric.value.replacingOccurrences(of: " rpm", with: "", options: .caseInsensitive)
            : metric.value
    }

    private static func drawIcon() {
        memoryIcon?.draw(in: NSRect(x: 2, y: 5, width: 14, height: 14))
    }

    private static func memoryUsageText(for snapshot: SystemMonitorSnapshot?) -> String {
        displayValue(for: .memoryUsage, snapshot: snapshot)
    }

    private static func drawMemoryUsage(_ value: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        (value as NSString).draw(
            in: NSRect(x: 19, y: 5, width: 33, height: 14),
            withAttributes: attributes
        )
    }

    private static func compactRate(_ bytesPerSecond: Int64?) -> String {
        guard let bytesPerSecond else { return "--" }
        var scaled = Double(max(0, bytesPerSecond))
        let units = ["B/s", "K/s", "M/s", "G/s"]
        var unitIndex = 0

        while scaled >= 1_000, unitIndex < units.count - 1 {
            scaled /= 1_000
            unitIndex += 1
        }

        let number: String
        if unitIndex == 0 || scaled >= 100 {
            number = String(format: "%.0f", scaled)
        } else if scaled >= 10 {
            number = String(format: "%.1f", scaled)
        } else {
            number = String(format: "%.2f", scaled)
        }
        return number + units[unitIndex]
    }

    private static func accessibilityLabel(for kind: MenuBarMetricKind) -> String {
        switch kind {
        case .cpuUsage:
            "CPU"
        case .gpuUsage:
            "GPU"
        case .memoryUsage:
            L10n.text("内存", "Memory")
        case .chipTemperature:
            L10n.text("芯片温度", "Chip temperature")
        case .fanSpeed:
            L10n.text("风扇转速", "Fan speed")
        case .networkSpeed:
            L10n.text("网络", "Network")
        }
    }
}
