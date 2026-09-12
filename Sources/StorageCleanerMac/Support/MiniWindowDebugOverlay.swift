import AppKit
import OSLog
import SwiftUI

#if DEBUG
enum MiniWindowDebugSupport {
    static let launchArguments = [
        "--debug-window-geometry",
        "--debug-mini-window-overlay",
    ]
    static let defaultsKey = "menuBar.debugMiniWindowOverlay"

    static var isEnabled: Bool {
        launchArguments.contains(where: ProcessInfo.processInfo.arguments.contains)
            || UserDefaults.standard.bool(forKey: defaultsKey)
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "StorageCleanerMac",
        category: "MiniWindowHover"
    )

    static func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}

struct MiniWindowDebugOverlay: View {
    @Environment(\.displayScale) private var displayScale

    let frames: [CGRect]
    let activeRegions: Set<GeekAttachedPanelRegion>
    let localPointerLocation: CGPoint?

    var body: some View {
        let corridors = connectorCorridors
        ZStack(alignment: .topLeading) {
            ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(debugColor(for: index), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
            ForEach(Array(corridors.enumerated()), id: \.offset) { _, corridor in
                Rectangle()
                    .fill(Color.orange.opacity(0.16))
                    .overlay {
                        Rectangle()
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                    .frame(width: corridor.width, height: corridor.height)
                    .offset(x: corridor.minX, y: corridor.minY)
            }
            Text(debugSummary)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var connectorCorridors: [CGRect] {
        let ordered = frames.sorted { $0.minX < $1.minX }
        return zip(ordered, ordered.dropFirst()).compactMap { left, right in
            let lowerBound = max(left.minY, right.minY)
            let upperBound = min(left.maxY, right.maxY)
            guard upperBound > lowerBound else { return nil }
            return CGRect(
                x: left.maxX,
                y: lowerBound,
                width: max(0, right.minX - left.maxX),
                height: upperBound - lowerBound
            )
        }
    }

    private var debugSummary: String {
        let pointer = NSEvent.mouseLocation
        let local = localPointerLocation.map { " local:\(Int($0.x)),\(Int($0.y))" } ?? ""
        return "hover:\(activeRegionNames) screen:\(Int(pointer.x)),\(Int(pointer.y))\(local)\n"
            + "open:\(MiniWindowStyleTokens.detailRevealDelay) close:\(MiniWindowStyleTokens.dismissDelay) "
            + "scale:\(String(format: "%.1f", displayScale)) bar:\(MiniWindowStyleTokens.barWidth)/\(MiniWindowStyleTokens.barSpacing)"
    }

    private var activeRegionNames: String {
        activeRegions.map { region in
            switch region {
            case .overview: "main"
            case .detail: "detail"
            case .tertiary: "history"
            }
        }
        .sorted()
        .joined(separator: ",")
    }

    private func debugColor(for index: Int) -> Color {
        switch index {
        case 0: .cyan
        case 1: .green
        default: .pink
        }
    }
}
#endif
