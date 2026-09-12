import SwiftUI

/// A value-only edit session. No selection, slider, preset or cancellation
/// changes the coordinator; the explicit Apply action is the only submitter.
struct FanControlDraft: Equatable {
    struct Configuration: Equatable {
        var mode: GeekFanControlMode?
        var synchronizesFans: Bool
        var percentagesByFan: [Int: Double]
    }

    private(set) var baseline: Configuration
    private(set) var configuration: Configuration

    init(
        telemetry: FanTelemetryState,
        observedMode: GeekFanControlMode?,
        synchronizesFans: Bool,
        confirmedFractions: [Int: Double] = [:]
    ) {
        let mode: GeekFanControlMode? = switch observedMode {
        case .fanSet, .maximum: .manual
        default: observedMode
        }
        let uniqueReadings = Set(telemetry.readings.map(\.index)).count == telemetry.readings.count
            ? telemetry.readings : []
        let percentages = Dictionary(uniqueKeysWithValues: uniqueReadings.compactMap { reading -> (Int, Double)? in
            guard let fraction = FanControlPlanner.manualEntryFraction(fanReadings: [reading]) else { return nil }
            let confirmed = mode == .manual ? confirmedFractions[reading.index] : nil
            return (reading.index, min(100, max(0, (confirmed ?? fraction) * 100)))
        })
        let initial = Configuration(mode: mode, synchronizesFans: synchronizesFans, percentagesByFan: percentages)
        baseline = initial
        configuration = initial
    }

    var hasChanges: Bool { configuration != baseline }
    var mode: GeekFanControlMode? { configuration.mode }
    var synchronizesFans: Bool { configuration.synchronizesFans }

    mutating func selectMode(_ mode: GeekFanControlMode) {
        guard [.systemAutomatic, .manual, .customCurve].contains(mode) else { return }
        configuration.mode = mode
    }

    mutating func setSynchronized(_ enabled: Bool) {
        guard enabled != configuration.synchronizesFans else { return }
        if enabled, let percentage = percentage(for: nil) {
            for fanID in configuration.percentagesByFan.keys {
                configuration.percentagesByFan[fanID] = percentage
            }
        }
        configuration.synchronizesFans = enabled
    }

    func percentage(for fanID: Int?) -> Double? {
        if let fanID { return configuration.percentagesByFan[fanID] }
        let values = configuration.percentagesByFan.values
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    mutating func setPercentage(_ value: Double, fanID: Int?) {
        guard value.isFinite else { return }
        let value = min(100, max(0, value))
        if let fanID, configuration.percentagesByFan[fanID] != nil {
            configuration.percentagesByFan[fanID] = value
        } else if fanID == nil {
            for fanID in configuration.percentagesByFan.keys {
                configuration.percentagesByFan[fanID] = value
            }
        }
    }

    mutating func cancel() { configuration = baseline }
    mutating func markConfirmed() { baseline = configuration }

    func targetRPM(fanID: Int?, telemetry: FanTelemetryState) -> Int? {
        let readings = telemetry.readings.filter { fanID == nil || $0.index == fanID }
        guard let percentage = percentage(for: fanID) else { return nil }
        return FanCurveEditor.targetRPM(percentage: percentage, fanReadings: readings)
    }

    mutating func setTargetRPM(_ rpm: Int, fanID: Int?, telemetry: FanTelemetryState) {
        let readings = telemetry.readings.filter { fanID == nil || $0.index == fanID }
        guard let minimum = FanCurveEditor.targetRPM(percentage: 0, fanReadings: readings),
              let maximum = FanCurveEditor.targetRPM(percentage: 100, fanReadings: readings),
              maximum > minimum else { return }
        setPercentage((Double(rpm) - Double(minimum)) / Double(maximum - minimum) * 100, fanID: fanID)
    }

    func matchesReadback(mode: GeekFanControlMode?, fractions: [Int: Double]) -> Bool {
        guard mode == configuration.mode else { return false }
        guard mode == .manual else { return true }
        guard !configuration.percentagesByFan.isEmpty,
              Set(fractions.keys) == Set(configuration.percentagesByFan.keys) else { return false }
        return configuration.percentagesByFan.allSatisfy { fanID, percentage in
            let expected = synchronizesFans ? self.percentage(for: nil)! : percentage
            return abs(fractions[fanID]! * 100 - expected) < 0.1
        }
    }

    /// Only called by an explicit Apply button. Existing coordinator validation,
    /// serialization, target ramping and authenticated readback remain intact.
    @MainActor
    func submit(to fanControl: FanControlCoordinator, telemetry: FanTelemetryState, thermalState: SystemThermalState) async -> Bool {
        guard let mode,
              !fanControl.isDataOnlyFixture,
              fanControl.helperState == .enabled,
              !fanControl.isApplying,
              !fanControl.isSwitchingMode else { return false }
        if mode != .systemAutomatic {
            guard telemetry.hasVerifiedRanges,
                  thermalState != .serious, thermalState != .critical else { return false }
        }
        switch mode {
        case .systemAutomatic:
            await fanControl.selectMode(.systemAutomatic)
        case .customCurve:
            await fanControl.applyFanCurveDraft()
        case .manual:
            guard Set(configuration.percentagesByFan.keys) == Set(telemetry.readings.map(\.index)) else { return false }
            if fanControl.selectedMode != .manual {
                await fanControl.selectMode(.manual)
            }
            guard fanControl.selectedMode == .manual, fanControl.helperState == .enabled else { return false }
            fanControl.setManualFansSynchronized(synchronizesFans)
            if synchronizesFans {
                guard let percentage = percentage(for: nil) else { return false }
                fanControl.commitManualPercentage(percentage)
            } else {
                // Stage every fan before the single final commit. These calls
                // share the existing debounce and never originate in a gesture.
                let fanIDs = configuration.percentagesByFan.keys.sorted()
                for fanID in fanIDs {
                    fanControl.updateManualPercentage(configuration.percentagesByFan[fanID]!, fanID: fanID)
                }
                if let last = fanIDs.last {
                    fanControl.commitManualPercentage(configuration.percentagesByFan[last]!, fanID: last)
                }
            }
        case .fanSet, .maximum:
            return false
        }
        return true
    }
}

struct FanSyncToggleRow: View {
    @Binding var draft: FanControlDraft
    var isDisabled = false

    var body: some View {
        Button {
            guard !isDisabled else { return }
            draft.setSynchronized(!draft.synchronizesFans)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: draft.synchronizesFans ? "checkmark.square.fill" : "square")
                Text(L10n.text("同步所有风扇", "Synchronize All Fans"))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .font(AdvancedPanelTypography.caption)
        .disabled(isDisabled)
        .accessibilityValue(draft.synchronizesFans ? L10n.text("已开启", "On") : L10n.text("已关闭", "Off"))
        .help(L10n.text("按各风扇自己的最低至最高量程同步目标比例；应用前不改变转速。", "Use the same fraction of each fan's own range. No speed changes before Apply."))
    }
}

struct FanManualSliderList: View {
    @Binding var draft: FanControlDraft
    let telemetry: FanTelemetryState
    let isDisabled: Bool
    var compact = false
    @State private var selectedFanID: Int?

    var body: some View {
        if draft.synchronizesFans {
            sliderRow(fanID: nil, title: L10n.text("全部风扇", "All Fans"))
        } else if let reading = telemetry.readings.first(where: { $0.index == selectedFanID }) ?? telemetry.readings.first {
            Picker(L10n.text("目标风扇", "Target Fan"), selection: Binding(
                get: { reading.index },
                set: { selectedFanID = $0 }
            )) {
                ForEach(telemetry.readings) { fan in Text(fan.displayName).tag(fan.index) }
            }
            .pickerStyle(.menu)
            .disabled(isDisabled)
            sliderRow(fanID: reading.index, title: reading.displayName)
        }
    }

    private func sliderRow(fanID: Int?, title: String) -> some View {
        let readings = telemetry.readings.filter { fanID == nil || $0.index == fanID }
        let minimum = FanCurveEditor.targetRPM(percentage: 0, fanReadings: readings)
        let maximum = FanCurveEditor.targetRPM(percentage: 100, fanReadings: readings)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 4)
                if !compact { Text(Self.actualRPM(fanID: fanID, telemetry: telemetry).map {
                    L10n.text("实际 ", "Actual ") + SystemFanSpeedFormat.string($0)
                } ?? L10n.text("实际 —", "Actual —"))
                    .monospacedDigit().foregroundStyle(.secondary) }
            }
            HStack(spacing: 5) {
                Text(fanID == nil && telemetry.fanCount > 1
                    ? L10n.text("平均目标", "Average Target")
                    : L10n.text("目标转速", "Target Speed"))
                Spacer(minLength: 4)
                if let target = draft.targetRPM(fanID: fanID, telemetry: telemetry) {
                    TextField("", value: Binding(
                        get: { draft.targetRPM(fanID: fanID, telemetry: telemetry) ?? target },
                        set: { guard !isDisabled else { return }; draft.setTargetRPM($0, fanID: fanID, telemetry: telemetry) }
                    ), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 62)
                    .disabled(isDisabled)
                    .accessibilityLabel(title + L10n.text("草稿目标 RPM", " Draft Target RPM"))
                    Text("rpm")
                } else {
                    Text("—")
                }
            }
            if let minimum, let maximum, let percentage = draft.percentage(for: fanID) {
                FanControlSlider(value: Binding(
                    get: { draft.percentage(for: fanID) ?? percentage },
                    set: { guard !isDisabled else { return }; draft.setPercentage($0, fanID: fanID) }
                ), isDisabled: isDisabled) { _ in }
                HStack {
                    Text(SystemFanSpeedFormat.string(minimum))
                    Spacer(minLength: 4)
                    Text(SystemFanSpeedFormat.string(maximum))
                }
                .foregroundStyle(.secondary)
                .help(L10n.text("硬件读取量程；0% 对应最低转速，不代表停转。", "Reported hardware range; 0% means minimum speed, not stopped."))
                if fanID == nil && !compact {
                    HStack(spacing: 4) {
                        ForEach([25.0, 50.0, 75.0, 100.0], id: \.self) { preset in
                            Button("\(Int(preset))%") {
                                guard !isDisabled else { return }
                                draft.setPercentage(preset, fanID: nil)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isDisabled)
                            .accessibilityLabel(L10n.text("草稿设为 \(Int(preset))%", "Set draft to \(Int(preset))%"))
                        }
                    }
                }
            } else {
                Text(L10n.text("量程未完整读取，保留实际转速监测。", "Range unavailable; actual RPM monitoring remains available."))
                    .foregroundStyle(.secondary)
            }
        }
        .font(AdvancedPanelTypography.caption)
        .accessibilityElement(children: .contain)
    }

    static func actualRPM(fanID: Int?, telemetry: FanTelemetryState) -> Int? {
        guard let fanID else { return telemetry.actualRPM }
        return telemetry.readings.first { $0.index == fanID }?.actualRPM
    }
}

/// A DragGesture-based slider. AppKit's NSSlider (behind SwiftUI's `Slider`)
/// runs a blocking event-tracking loop while the mouse is down, which
/// freezes every MainActor task — telemetry publishing, lease renewals and
/// UI updates — long enough to trip the helper's fan-control watchdog
/// mid-drag ("lease expired" reverts) and to make the panel visibly lag. A
/// gesture-driven slider keeps the run loop alive for the whole drag.
struct FanControlSlider: View {
    @Environment(\.panelChartAccentColor) private var panelChartAccentColor

    @Binding var value: Double
    var isDisabled = false
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    private let range: ClosedRange<Double> = 0...100
    private let knobDiameter: CGFloat = 13

    var body: some View {
        GeometryReader { proxy in
            let usableWidth = max(1, proxy.size.width - knobDiameter)
            let fraction = min(max(value / range.upperBound, 0), 1)
            let knobOffset = usableWidth * CGFloat(fraction)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(height: 4)
                Capsule()
                    .fill(controlTint)
                    .frame(width: knobOffset + knobDiameter / 2, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(x: knobOffset)
            }
            .frame(maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard !isDisabled else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        value = resolvedValue(
                            locationX: gesture.location.x,
                            usableWidth: usableWidth
                        )
                    }
                    .onEnded { gesture in
                        guard !isDisabled else { isDragging = false; return }
                        value = resolvedValue(
                            locationX: gesture.location.x,
                            usableWidth: usableWidth
                        )
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 22)
        .transaction { $0.animation = nil }
        .opacity(isDisabled ? 0.45 : 1)
        .allowsHitTesting(!isDisabled)
        .disabled(isDisabled)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("风扇转速", "Fan Speed"))
        .accessibilityValue(Text("\(Int(value.rounded()))%"))
        .accessibilityHint(L10n.text(
            "拖动或使用辅助功能增减目标转速",
            "Drag or use accessibility actions to change the target speed"
        ))
        .accessibilityAdjustableAction { direction in
            guard !isDisabled else { return }
            switch direction {
            case .increment:
                value = min(range.upperBound, value + 5)
            case .decrement:
                value = max(range.lowerBound, value - 5)
            @unknown default:
                return
            }
            onEditingChanged(false)
        }
    }

    private func resolvedValue(locationX: CGFloat, usableWidth: CGFloat) -> Double {
        let clamped = min(max(0, locationX - knobDiameter / 2), usableWidth)
        return (Double(clamped / usableWidth) * range.upperBound).rounded()
    }

    private var controlTint: Color {
        panelChartAccentColor ?? .accentColor
    }
}
