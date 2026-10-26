import SwiftUI

/// D152: iStat Menus 7.30's manual fan slider (`-[BBRSensorsMenuFanSlider
/// drawRect:]`, `mouseDown:`, `mouseDragged:`, `mouseUp:`), in points in a
/// view as wide as its text section (W) and 30 tall:
/// - the label at (8, −3, W − 16, 15) in the label style, the value
///   '%.0f%%' right-aligned to W − 10 in the value style;
/// - the track (8, 18, W − 16, 8) at radius 4 in the theme's graph border
///   color, the same rect p × (W − 16) wide in the primary color;
/// - the knob, a 16 pt circle at (p × (W − 16), 14) in the value color;
/// - a press on the knob (its 16 pt box at (p × (W − 16), 17)) starts a
///   drag; a press elsewhere between 8 and W − 8 sets p = (x − 8) / (W − 16)
///   and writes at once, then drags; a press outside does nothing;
/// - a drag clamps the whole-point x to [8, W − 8] and writes 0.2 s after
///   the last move (`FanControlSafetyPolicy.manualControlDebounce`); the
///   release writes at once.
/// The container (`BBRSensorsManualFanItem`) stacks the sliders 8 apart.
enum FanControlSliderGeometry {
    static let height: CGFloat = 30
    static let spacing: CGFloat = 8
    static let inset: CGFloat = 8
    static let labelTop: CGFloat = -3
    static let labelHeight: CGFloat = 15
    static let valueTrailing: CGFloat = 10
    static let trackTop: CGFloat = 18
    static let trackHeight: CGFloat = 8
    static let trackRadius: CGFloat = 4
    static let knobSize: CGFloat = 16
    static let knobTop: CGFloat = 14
    static let knobHitTop: CGFloat = 17
    /// One VoiceOver increment or decrement (ours; iStat has none).
    static let accessibilityStep = 0.05

    static func clamped(_ fraction: Double) -> Double {
        min(1, max(0, fraction.isFinite ? fraction : 0))
    }

    static func trackWidth(_ width: CGFloat) -> CGFloat {
        max(0, width - 2 * inset)
    }

    /// The knob's leading edge: p × (W − 16), so its center is on the track
    /// at 8 + p × (W − 16).
    static func knobLeading(fraction: Double, width: CGFloat) -> CGFloat {
        CGFloat(clamped(fraction)) * trackWidth(width)
    }

    static func knobHitRect(fraction: Double, width: CGFloat) -> CGRect {
        CGRect(x: knobLeading(fraction: fraction, width: width), y: knobHitTop,
               width: knobSize, height: knobSize)
    }

    /// The value a press at x sets; nil outside [8, W − 8].
    static func fraction(pressAt x: CGFloat, width: CGFloat) -> Double? {
        guard trackWidth(width) > 0, x >= inset, x <= width - inset else { return nil }
        return clamped(Double((x - inset) / trackWidth(width)))
    }

    /// The value a drag at x sets: iStat takes the whole-point x and clamps
    /// it to [8, (int)(W − 8)].
    static func fraction(dragAt x: CGFloat, width: CGFloat) -> Double {
        guard trackWidth(width) > 0 else { return 0 }
        let upper = (width - inset).rounded(.towardZero)
        let point = min(max(x.rounded(.towardZero), inset), upper)
        return clamped(Double((point - inset) / trackWidth(width)))
    }

    static func valueText(fraction: Double) -> String {
        String(format: "%.0f%%", clamped(fraction) * 100)
    }

    /// n sliders: 30n + 8(n − 1); none is empty.
    static func listHeight(count: Int) -> CGFloat {
        count > 0 ? CGFloat(count) * height + CGFloat(count - 1) * spacing : 0
    }

    /// iStat's mouse handlers as a value, so they are testable without a
    /// window: a press on the knob holds the stored value, a press beside it
    /// writes at once, a press outside makes the rest of the gesture do
    /// nothing, a move stores for the debounced write, the release writes
    /// what the gesture holds.
    struct Tracking: Equatable {
        enum Write: Equatable {
            /// Store the value; the coordinator writes it after the debounce.
            case drag(Double)
            /// Write the value now.
            case commit(Double)
        }

        private typealias Geometry = FanControlSliderGeometry
        /// The value the running gesture holds; nil without a gesture.
        private(set) var fraction: Double?
        /// The gesture began outside the track.
        private(set) var isIgnored = false

        /// A gesture step (`mouseDown:`, then `mouseDragged:`) over the
        /// stored value.
        mutating func changed(start: CGPoint, location: CGPoint, width: CGFloat, stored: Double) -> [Write] {
            guard !isIgnored else { return [] }
            var writes: [Write] = []
            if fraction == nil {
                if Geometry.knobHitRect(fraction: stored, width: width).contains(start) {
                    fraction = Geometry.clamped(stored)
                } else if let value = Geometry.fraction(pressAt: start.x, width: width) {
                    fraction = value
                    writes.append(.commit(value))
                } else {
                    isIgnored = true
                    return []
                }
                // The press itself does not move the knob; the drag does.
                guard location != start else { return writes }
            }
            let value = Geometry.fraction(dragAt: location.x, width: width)
            fraction = value
            writes.append(.drag(value))
            return writes
        }

        /// The release (`mouseUp:`); the next gesture starts afresh.
        mutating func ended() -> [Write] {
            defer { self = Tracking() }
            guard !isIgnored, let fraction else { return [] }
            return [.commit(fraction)]
        }
    }
}

/// One slider of the manual section. The value comes from the coordinator
/// and is written back through it; the view keeps only the gesture.
///
/// A DragGesture rather than AppKit's NSSlider (behind SwiftUI's `Slider`):
/// NSSlider runs a blocking event-tracking loop while the mouse is down,
/// which freezes every MainActor task — telemetry publishing, lease
/// renewals and UI updates — long enough to trip the helper's fan-control
/// watchdog mid-drag ("lease expired" reverts) and to make the panel
/// visibly lag. A gesture keeps the run loop alive for the whole drag.
struct FanControlSlider: View {
    private typealias Geometry = FanControlSliderGeometry
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    /// The stored value, 0 … 1.
    let fraction: Double
    /// A drag step: store the value; the coordinator writes after the debounce.
    let onDrag: (Double) -> Void
    /// A press beside the knob, the release or an accessibility step: write now.
    let onCommit: (Double) -> Void
    @State private var tracking = Geometry.Tracking()

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let value = Geometry.clamped(fraction)
            ZStack(alignment: .topLeading) {
                Text(title)
                    .geekIStatLabelText()
                    .frame(width: Geometry.trackWidth(width), height: Geometry.labelHeight, alignment: .leading)
                    .offset(x: Geometry.inset, y: Geometry.labelTop)
                Text(Geometry.valueText(fraction: value))
                    .geekIStatValueText()
                    .frame(width: max(0, width - 2 * Geometry.valueTrailing), height: Geometry.labelHeight,
                           alignment: .trailing)
                    .offset(x: Geometry.valueTrailing, y: Geometry.labelTop)
                RoundedRectangle(cornerRadius: Geometry.trackRadius, style: .circular)
                    .fill(panelChromePalette?.graphBorder ?? Color.primary.opacity(0.2))
                    .frame(width: Geometry.trackWidth(width), height: Geometry.trackHeight)
                    .offset(x: Geometry.inset, y: Geometry.trackTop)
                RoundedRectangle(cornerRadius: Geometry.trackRadius, style: .circular)
                    .fill(metricColors.sensorGraph)
                    .frame(width: CGFloat(value) * Geometry.trackWidth(width), height: Geometry.trackHeight)
                    .offset(x: Geometry.inset, y: Geometry.trackTop)
                Circle()
                    .fill(GeekIStatCardGeometry.valueColor(panelChromePalette))
                    .frame(width: Geometry.knobSize, height: Geometry.knobSize)
                    .offset(x: Geometry.knobLeading(fraction: value, width: width), y: Geometry.knobTop)
            }
            .frame(width: width, height: Geometry.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { step in
                        guard isEnabled else { return }
                        perform(tracking.changed(start: step.startLocation, location: step.location,
                                                 width: width, stored: fraction))
                    }
                    .onEnded { _ in
                        let writes = tracking.ended()
                        guard isEnabled else { return }
                        perform(writes)
                    }
            )
        }
        .frame(height: Geometry.height)
        .transaction { $0.animation = nil }
        .opacity(isEnabled ? 1 : 0.55)
        .allowsHitTesting(isEnabled)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(Text(Geometry.valueText(fraction: fraction)))
        .accessibilityHint(L10n.text(
            "拖动或使用辅助功能增减目标转速；0% 为硬件最低转速，不代表停转。",
            "Drag or use accessibility actions to change the target speed; 0% is the hardware minimum, not stopped."
        ))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let value = Geometry.clamped(fraction)
            switch direction {
            case .increment: onCommit(min(1, value + Geometry.accessibilityStep))
            case .decrement: onCommit(max(0, value - Geometry.accessibilityStep))
            @unknown default: return
            }
        }
    }

    private func perform(_ writes: [Geometry.Tracking.Write]) {
        for write in writes {
            switch write {
            case .drag(let value): onDrag(value)
            case .commit(let value): onCommit(value)
            }
        }
    }
}

/// D152: iStat's slider container (`-[BBRSensorsManualFanItem update]`): one
/// slider labelled Fans while the fans are synchronized (always with a
/// single fan), otherwise one per fan under its name; iStat's fan groups
/// have no counterpart here. Was one slider at a time with a fan picker.
struct FanManualSliderList: View {
    struct Slider: Equatable, Identifiable {
        /// nil for the synchronized slider.
        let fanID: Int?
        let title: String
        var id: Int { fanID ?? -1 }
    }

    @ObservedObject var fanControl: FanControlCoordinator
    let readings: [SystemFanReading]

    /// The sliders need every fan's verified range and each fan once; the
    /// planner writes nothing otherwise (as the draft before D152).
    static func isAvailable(for telemetry: FanTelemetryState) -> Bool {
        telemetry.hasVerifiedRanges
            && Set(telemetry.readings.map(\.index)).count == telemetry.readings.count
    }

    static func sliders(readings: [SystemFanReading], synchronizes: Bool) -> [Slider] {
        guard !readings.isEmpty, Set(readings.map(\.index)).count == readings.count else { return [] }
        if synchronizes || readings.count < 2 {
            return [Slider(fanID: nil, title: L10n.text("风扇", "Fans"))]
        }
        return readings.map { Slider(fanID: $0.index, title: $0.displayName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FanControlSliderGeometry.spacing) {
            ForEach(Self.sliders(readings: readings, synchronizes: fanControl.synchronizesManualFans)) { slider in
                FanControlSlider(
                    title: slider.title,
                    fraction: fanControl.manualPercentage(for: slider.fanID) / 100,
                    onDrag: { fanControl.updateManualPercentage($0 * 100, fanID: slider.fanID) },
                    onCommit: { fanControl.commitManualPercentage($0 * 100, fanID: slider.fanID) }
                )
                .accessibilityIdentifier("fan-manual-slider-\(slider.id)")
#if DEBUG
                .layoutProbe("fan.manual.slider.\(slider.id)")
#endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
