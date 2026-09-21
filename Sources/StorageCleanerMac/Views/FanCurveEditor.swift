import AppKit
import FanControlShared
import SwiftUI

extension FanCurveSensor {
    var displayTitle: String {
        switch self {
        case .chipMaximum: L10n.text("芯片最高温度", "Chip Maximum")
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .performanceCore: L10n.text("性能核心", "Performance Cores")
        case .efficiencyCore: L10n.text("能效核心", "Efficiency Cores")
        }
    }
}

struct FanCurveEditor: View {
    @Environment(\.undoManager) private var undoManager
    @ObservedObject private var fanControl: FanControlCoordinator
    @ObservedObject private var store: FanCurveStore
    @StateObject private var session: FanCurveEditorSession
    let fanReadings: [SystemFanReading]
    var compact: Bool

    init(
        fanControl: FanControlCoordinator,
        fanReadings: [SystemFanReading],
        compact: Bool = false
    ) {
        _fanControl = ObservedObject(wrappedValue: fanControl)
        _store = ObservedObject(wrappedValue: fanControl.curveStore)
        _session = StateObject(wrappedValue: FanCurveEditorSession(
            profile: fanControl.curveStore.draftProfile,
            commitDraft: { [weak store = fanControl.curveStore] profile in
                _ = store?.replaceDraft(profile)
            }
        ))
        self.fanReadings = fanReadings
        self.compact = compact
    }

    private var points: [FanCurvePoint] { session.points }

    private var selectedPoint: FanCurvePoint? {
        session.selectedPoint
    }

    private var currentTemperature: Double? {
        fanControl.previewTemperature(for: session.draftProfile.sensor)
    }

    private var displayedAppliedProfile: FanCurveProfile? { store.appliedProfile }
    private var displayedRuntimeState: FanCurveRuntimeState { fanControl.curveRuntimeState }
    private var displayedHasUnappliedChanges: Bool {
        session.hasUnappliedChanges(comparedWith: store.appliedProfile)
    }

    private var previewPercentage: Double? {
        guard let currentTemperature else { return nil }
        return FanCurveInterpolator.percentage(
            at: currentTemperature,
            points: session.draftProfile.points
        )
    }

    private var previewTargetRPM: Int? {
        guard let previewPercentage else { return nil }
        return Self.targetRPM(percentage: previewPercentage, fanReadings: fanReadings)
    }

    /// The display uses the same per-fan rounding and validated ranges as the
    /// control mapper. Averaging happens after mapping each fan's target RPM.
    nonisolated static func targetRPM(percentage: Double, fanReadings: [SystemFanReading]) -> Int? {
        let ranges = fanReadings.compactMap { reading -> FanCurveFanRange? in
            guard let minimumRPM = reading.minimumRPM,
                  let maximumRPM = reading.maximumRPM,
                  maximumRPM > minimumRPM else { return nil }
            return FanCurveFanRange(
                fanID: reading.index,
                minimumRPM: minimumRPM,
                maximumRPM: maximumRPM,
                actualRPM: reading.actualRPM
            )
        }
        guard ranges.count == fanReadings.count,
              let targets = try? FanCurveRPMMapper.targets(
                  percentage: percentage,
                  ranges: ranges
              ) else { return nil }
        return Int((targets.values.reduce(0.0) { $0 + Double($1) }
            / Double(targets.count)).rounded())
    }

    private var hasRPMAxis: Bool {
        Self.targetRPM(percentage: 0, fanReadings: fanReadings) != nil
    }

    private var canApply: Bool {
        session.validationError == nil
            && displayedHasUnappliedChanges
            && fanControl.helperState == .enabled
            && !fanControl.isDataOnlyFixture
            && !fanControl.isApplying
            && !fanControl.isSwitchingMode
            && currentTemperature != nil
            && hasRPMAxis
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? MiniWindowStyleTokens.rowSpacing : 10) {
            if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("风扇曲线", "Fan Curve"))
                        .font(AdvancedPanelTypography.sectionTitle)
                    Text(L10n.text(
                        "根据温度自动调节风扇转速",
                        "Automatically adjust fan speed from temperature"
                    ))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                }
            }

            sensorPicker

            HStack(spacing: 6) {
                Text(hasRPMAxis
                    ? (fanReadings.count > 1
                        ? L10n.text("平均目标 RPM", "Average Target RPM")
                        : L10n.text("目标 RPM", "Target RPM"))
                    : L10n.text("风扇输出 · %", "Fan Output · %"))
                Spacer(minLength: 0)
                if hasRPMAxis {
                    Text(L10n.text("0% 对应最低转速", "0% = minimum speed"))
                } else {
                    Text(L10n.text("RPM 量程未读取", "RPM range unavailable"))
                }
            }
            .font(AdvancedPanelTypography.caption)
            .foregroundStyle(.secondary)
            .help(L10n.text(
                "RPM 由各风扇实际读取的最低和最高转速换算；多风扇取目标转速均值。0% 对应最低转速，不代表停转。",
                "RPM is mapped from each fan's reported minimum and maximum, averaged across fans. 0% means the minimum speed, not a stopped fan."
            ))

            FanCurvePlot(
                points: points,
                selectedPointID: selectedPoint?.id,
                hoveredPointID: session.hoveredPointID,
                draggingPointID: session.draggingPointID,
                currentTemperature: currentTemperature,
                currentPercentage: previewPercentage,
                fanReadings: fanReadings,
                onSelect: session.select,
                onHover: hoverPoint,
                onDragBegan: beginDraggingPoint,
                onDragChanged: dragPoint,
                onDragEnded: endDraggingPoint,
                onNudge: nudgePoint,
                onDelete: deletePoint
            )
            .frame(height: compact ? 150 : 188)
            .transaction { $0.animation = nil }

            if let point = selectedPoint {
                pointControls(point)
            }

            editActions
            previewRows

            if fanControl.isDataOnlyFixture {
                Text(L10n.text("FIXTURE · 草稿可编辑；禁止硬件应用或 Helper 申请。", "FIXTURE · Draft editing only; hardware writes and Helper registration blocked."))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationError = session.validationError {
                Text(validationText(validationError))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
            } else if fanControl.helperState == .requiresApproval {
                Text(L10n.text(
                    "系统批准后即可应用温控曲线。",
                    "You can apply the fan curve after system approval."
                ))
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
            } else if displayedHasUnappliedChanges,
                      displayedAppliedProfile != nil {
                Text(L10n.text(
                    "有未应用更改；上次已应用曲线保持不变。",
                    "Unapplied changes do not alter the previously applied curve."
                ))
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(AppDesignTokens.Palette.information)
            } else if displayedAppliedProfile == nil {
                Text(L10n.text("尚未应用曲线", "No curve is active"))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = fanControl.lastMessage {
                Text(message)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(messageTint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            bottomActions
        }
        .onAppear {
            session.synchronize(with: store.draftProfile)
        }
        .onChange(of: store.draftProfile) { _, profile in
            session.synchronize(with: profile)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("风扇温控曲线编辑器", "Fan temperature-curve editor"))
    }

    private var sensorPicker: some View {
        HStack(spacing: 8) {
            Text(L10n.text("温度来源", "Temperature Source"))
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker(
                L10n.text("温度来源", "Temperature Source"),
                selection: Binding(
                    get: { session.draftProfile.sensor },
                    set: { sensor in
                        session.setSensor(sensor, undoManager: undoManager)
                    }
                )
            ) {
                ForEach(selectableSensors) { sensor in
                    Text(sensor.displayTitle).tag(sensor)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(selectableSensors.isEmpty)
            .accessibilityLabel(L10n.text("曲线温度来源", "Fan-curve temperature source"))
        }
    }

    private var selectableSensors: [FanCurveSensor] {
        let available = fanControl.availableCurveSensors
        if available.contains(session.draftProfile.sensor) { return available }
        return available.isEmpty ? [session.draftProfile.sensor] : available
    }

    private var editActions: some View {
        HStack(spacing: 8) {
            Button {
                _ = session.addPoint(undoManager: undoManager)
            } label: {
                Label(L10n.text("增加控制点", "Add Point"), systemImage: "plus")
            }
            .disabled(points.count >= FanCurveProfile.maximumPointCount)
            .accessibilityLabel(L10n.text("增加风扇曲线控制点", "Add fan-curve point"))

            Button(role: .destructive) {
                guard let selectedPointID = session.selectedPointID else { return }
                session.removePoint(id: selectedPointID, undoManager: undoManager)
            } label: {
                Label(L10n.text("删除控制点", "Delete Point"), systemImage: "minus")
            }
            .disabled(
                points.count <= FanCurveProfile.minimumPointCount
                    || selectedPoint?.id == points.last?.id
            )
            .accessibilityLabel(L10n.text("删除选中的风扇曲线控制点", "Delete selected fan-curve point"))

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func pointControls(_ point: FanCurvePoint) -> some View {
        HStack(spacing: 10) {
            Stepper(
                value: Binding(
                    get: { point.temperatureCelsius },
                    set: {
                        session.updatePoint(
                            id: point.id,
                            temperatureCelsius: $0,
                            speedFraction: point.speedFraction,
                            undoManager: undoManager
                        )
                    }
                ),
                in: FanCurveProfile.temperatureRange,
                step: 1
            ) {
                LabeledContent(
                    L10n.text("温度", "Temperature"),
                    value: "\(Int(point.temperatureCelsius.rounded()))°C"
                )
                .monospacedDigit()
            }
            .accessibilityLabel(L10n.text("选中控制点温度", "Selected point temperature"))

            Stepper(
                value: Binding(
                    get: { point.fanPercentage },
                    set: {
                        session.updatePoint(
                            id: point.id,
                            temperatureCelsius: point.temperatureCelsius,
                            speedFraction: $0 / 100,
                            undoManager: undoManager
                        )
                    }
                ),
                in: 0...100,
                step: 1
            ) {
                LabeledContent(
                    L10n.text("风扇", "Fan"),
                    value: "\(Int(point.fanPercentage.rounded()))%"
                )
                .monospacedDigit()
            }
            .disabled(point.id == points.last?.id)
            .accessibilityLabel(L10n.text("选中控制点风扇百分比", "Selected point fan percentage"))
        }
        .font(AdvancedPanelTypography.caption)
    }

    private var previewRows: some View {
        VStack(spacing: 3) {
            valueRow(
                L10n.text("当前温度", "Current Temperature"),
                currentTemperature.map { String(format: "%.1f°C", $0) } ?? "—"
            )
            valueRow(
                L10n.text("草稿预计输出", "Draft Estimated Output"),
                previewPercentage.map { "\(Int($0.rounded()))%" } ?? "—"
            )
            valueRow(
                L10n.text("草稿预计目标", "Draft Estimated Target"),
                previewTargetRPM.map(SystemFanSpeedFormat.string) ?? "—"
            )
            if fanControl.observedMode == .customCurve,
               let applied = displayedRuntimeState.appliedPercentage {
                valueRow(
                    L10n.text("当前运行输出", "Active Output"),
                    "\(Int(applied.rounded()))%"
                )
            }
        }
    }

    private var bottomActions: some View {
        HStack(spacing: 8) {
            Button(L10n.text("恢复默认", "Restore Default")) {
                session.restoreDefault(undoManager: undoManager)
            }
            Button(L10n.text("取消更改", "Discard Changes")) {
                session.discardChanges(
                    to: store.savedProfile,
                    undoManager: undoManager
                )
            }
            .disabled(!session.hasUnsavedChanges(comparedWith: store.savedProfile))

            Spacer(minLength: 0)

            Button(L10n.text("应用曲线", "Apply Curve")) {
                guard canApply else { return }
                guard store.replaceDraft(session.draftProfile) else { return }
                Task { await fanControl.applyFanCurveDraft() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canApply)
            .accessibilityHint(L10n.text(
                "经 Helper 验证后才会改变实际风扇转速",
                "Actual fan speed changes only after helper validation"
            ))
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(AdvancedPanelTypography.caption)
    }

    private func hoverPoint(_ id: UUID?) {
        session.setHoveredPoint(id)
        (id == nil ? NSCursor.arrow : NSCursor.openHand).set()
    }

    private func beginDraggingPoint(_ id: UUID) {
        session.beginDrag(pointID: id)
        NSCursor.closedHand.set()
    }

    private func dragPoint(
        _ id: UUID,
        _ translation: CGSize,
        _ transform: FanCurvePlotTransform
    ) {
        session.updateDrag(
            pointID: id,
            translation: translation,
            transform: transform
        )
    }

    private func endDraggingPoint(
        _ id: UUID,
        _ translation: CGSize,
        _ transform: FanCurvePlotTransform
    ) {
        _ = session.endDrag(
            pointID: id,
            translation: translation,
            transform: transform,
            undoManager: undoManager
        )
        (session.hoveredPointID == nil ? NSCursor.arrow : NSCursor.openHand).set()
    }

    private func nudgePoint(
        _ id: UUID,
        _ direction: MoveCommandDirection,
        _ amount: Double
    ) {
        guard let point = points.first(where: { $0.id == id }) else { return }
        switch direction {
        case .left:
            session.updatePoint(
                id: id,
                temperatureCelsius: point.temperatureCelsius - amount,
                speedFraction: point.speedFraction,
                undoManager: undoManager
            )
        case .right:
            session.updatePoint(
                id: id,
                temperatureCelsius: point.temperatureCelsius + amount,
                speedFraction: point.speedFraction,
                undoManager: undoManager
            )
        case .up:
            session.updatePoint(
                id: id,
                temperatureCelsius: point.temperatureCelsius,
                speedFraction: point.speedFraction + amount / 100,
                undoManager: undoManager
            )
        case .down:
            session.updatePoint(
                id: id,
                temperatureCelsius: point.temperatureCelsius,
                speedFraction: point.speedFraction - amount / 100,
                undoManager: undoManager
            )
        @unknown default:
            break
        }
    }

    private func deletePoint(_ id: UUID) {
        session.removePoint(id: id, undoManager: undoManager)
    }

    private var messageTint: Color {
        fanControl.lastMessage?.contains(L10n.text("已由 Helper", "applied and verified")) == true
            ? AppDesignTokens.Palette.success
            : .secondary
    }

    private func validationText(_ error: FanCurveError) -> String {
        switch error {
        case .invalidCurvePointCount: L10n.text("曲线需要 3–8 个控制点。", "The curve needs 3–8 points.")
        case .invalidCurveTemperature: L10n.text("温度必须在 25–100°C。", "Temperature must be 25–100°C.")
        case .invalidCurvePercentage: L10n.text("风扇输出必须在 0–100%。", "Fan output must be 0–100%.")
        case .nonIncreasingTemperatures: L10n.text("温度必须递增且至少间隔 2°C。", "Temperatures must increase by at least 2°C.")
        case .decreasingFanPercentage: L10n.text("温度升高时风扇百分比不能降低。", "Fan output cannot fall as temperature rises.")
        case .missingFullSpeedPoint: L10n.text("最后一个控制点必须达到 100%。", "The final point must reach 100%.")
        case .fullSpeedPointTooHot: L10n.text("曲线必须在 90°C 前达到 100%。", "The curve must reach 100% by 90°C.")
        default: L10n.text("曲线配置无效。", "The fan-curve configuration is invalid.")
        }
    }

}

struct FanCurveCompactPreview: View {
    let points: [FanCurvePoint]
    let currentTemperature: Double?
    let currentPercentage: Double?

    var body: some View {
        FanCurvePlot(
            points: points,
            selectedPointID: nil,
            hoveredPointID: nil,
            draggingPointID: nil,
            currentTemperature: currentTemperature,
            currentPercentage: currentPercentage,
            onSelect: nil,
            onHover: nil,
            onDragBegan: nil,
            onDragChanged: nil,
            onDragEnded: nil,
            onNudge: nil,
            onDelete: nil
        )
        .accessibilityLabel(L10n.text("当前应用风扇曲线预览", "Active fan-curve preview"))
    }
}

private struct FanCurvePlot: View {
    @FocusState private var focusedPointID: UUID?

    let points: [FanCurvePoint]
    let selectedPointID: UUID?
    let hoveredPointID: UUID?
    let draggingPointID: UUID?
    let currentTemperature: Double?
    let currentPercentage: Double?
    var fanReadings: [SystemFanReading] = []
    let onSelect: ((UUID) -> Void)?
    let onHover: ((UUID?) -> Void)?
    let onDragBegan: ((UUID) -> Void)?
    let onDragChanged: ((UUID, CGSize, FanCurvePlotTransform) -> Void)?
    let onDragEnded: ((UUID, CGSize, FanCurvePlotTransform) -> Void)?
    let onNudge: ((UUID, MoveCommandDirection, Double) -> Void)?
    let onDelete: ((UUID) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let isCompact = onDragChanged == nil
            let leftInset: CGFloat = isCompact ? 8 : (usesRPMAxis ? 48 : 30)
            let plot = CGRect(
                x: leftInset,
                y: isCompact ? 4 : 10,
                width: max(1, proxy.size.width - leftInset - (isCompact ? 8 : 10)),
                height: max(1, proxy.size.height - (isCompact ? 8 : 34))
            )
            let transform = FanCurvePlotTransform(plot: plot)
            ZStack {
                RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
                gridPath(in: plot)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
                if let currentTemperature {
                    Path { path in
                        let x = transform.x(for: currentTemperature)
                        path.move(to: CGPoint(x: x, y: plot.minY))
                        path.addLine(to: CGPoint(x: x, y: plot.maxY))
                    }
                    .stroke(
                        AppDesignTokens.Palette.information.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                }
                if let currentPercentage {
                    Path { path in
                        let y = transform.y(forPercentage: currentPercentage)
                        path.move(to: CGPoint(x: plot.minX, y: y))
                        path.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                    .stroke(
                        AppDesignTokens.Palette.tertiary.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                }
                curvePath(in: plot)
                    .stroke(
                        AppDesignTokens.Palette.tertiary,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                ForEach(points) { point in
                    pointView(point, transform: transform, isCompact: isCompact)
                }
                if !isCompact {
                    axisLabels(plot: plot, size: proxy.size)
                }
            }
            .coordinateSpace(name: "fanCurvePlot")
            .onChange(of: focusedPointID) { _, id in
                if let id { onSelect?(id) }
            }
        }
    }

    private func pointView(
        _ point: FanCurvePoint,
        transform: FanCurvePlotTransform,
        isCompact: Bool
    ) -> some View {
        let isSelected = point.id == selectedPointID
        let isHovered = point.id == hoveredPointID
        let isDragging = point.id == draggingPointID
        return ZStack {
            if !isCompact, isHovered || isDragging {
                Circle()
                    .stroke(AppDesignTokens.Palette.tertiary.opacity(0.45), lineWidth: 1)
                    .frame(width: 20, height: 20)
            }
            Circle()
                .fill(
                    isSelected
                        ? AppDesignTokens.Palette.tertiary
                        : Color(nsColor: .controlBackgroundColor)
                )
                .overlay {
                    Circle().stroke(AppDesignTokens.Palette.tertiary, lineWidth: 1.5)
                }
                .frame(width: isCompact ? 8 : 12, height: isCompact ? 8 : 12)
            if !isCompact, focusedPointID == point.id {
                Circle()
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
                    .frame(width: 24, height: 24)
            }
        }
            .frame(width: isCompact ? 8 : 28, height: isCompact ? 8 : 28)
            .contentShape(Circle())
            .position(transform.position(for: point))
            .onTapGesture { onSelect?(point.id) }
            .gesture(
                DragGesture(
                    minimumDistance: isCompact ? .infinity : 0,
                    coordinateSpace: .named("fanCurvePlot")
                )
                    .onChanged { value in
                        guard !isCompact else { return }
                        onDragBegan?(point.id)
                        onDragChanged?(point.id, value.translation, transform)
                    }
                    .onEnded { value in
                        guard !isCompact else { return }
                        onDragEnded?(point.id, value.translation, transform)
                    }
            )
            .onHover { hovering in
                guard !isCompact else { return }
                onHover?(hovering ? point.id : nil)
            }
            .focusable(!isCompact)
            .focused($focusedPointID, equals: point.id)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                guard !isCompact, let direction = moveDirection(for: press.key) else {
                    return .ignored
                }
                onSelect?(point.id)
                onNudge?(point.id, direction, press.modifiers.contains(.shift) ? 5 : 1)
                return .handled
            }
            .onKeyPress(.delete) {
                guard !isCompact else { return .ignored }
                onDelete?(point.id)
                return .handled
            }
            .onKeyPress(.space) {
                guard !isCompact else { return .ignored }
                onSelect?(point.id)
                return .handled
            }
            .onKeyPress(.return) {
                guard !isCompact else { return .ignored }
                onSelect?(point.id)
                return .handled
            }
            .overlay(alignment: .top) {
                if isDragging {
                    Text("\(Int(point.temperatureCelsius.rounded()))°C · \(Int(point.fanPercentage.rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppAppearanceColors.ink.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .miniWindowTooltipChrome()
                        .fixedSize()
                        .offset(y: -28)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(accessibilityLabel(for: point))
            .accessibilityValue(
                "\(Int(point.temperatureCelsius.rounded()))°C, \(Int(point.fanPercentage.rounded()))%"
            )
            .accessibilityHint(L10n.text(
                "拖动可同时调整温度和风扇百分比；方向键微调，按住 Shift 每次调整 5。",
                "Drag to change temperature and fan percentage; use arrow keys, with Shift for steps of five."
            ))
            .accessibilityAdjustableAction { direction in
                guard !isCompact else { return }
                onNudge?(
                    point.id,
                    direction == .increment ? .up : .down,
                    1
                )
            }
    }

    private func accessibilityLabel(for point: FanCurvePoint) -> String {
        let index = (points.firstIndex(where: { $0.id == point.id }) ?? 0) + 1
        return L10n.text(
            "控制点 \(index)，\(Int(point.temperatureCelsius.rounded()))°C，\(Int(point.fanPercentage.rounded()))%",
            "Point \(index), \(Int(point.temperatureCelsius.rounded()))°C, \(Int(point.fanPercentage.rounded()))%"
        )
    }

    private func moveDirection(for key: KeyEquivalent) -> MoveCommandDirection? {
        switch key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        case .downArrow: .down
        default: nil
        }
    }

    @ViewBuilder
    private func axisLabels(plot: CGRect, size: CGSize) -> some View {
        ForEach([100, 50, 0], id: \.self) { percentage in
            Text(axisLabel(percentage: percentage))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: max(1, plot.minX - 8), alignment: .trailing)
                .position(
                    x: (plot.minX - 8) / 2,
                    y: min(plot.maxY - 2, max(plot.minY + 4,
                        FanCurvePlotTransform(plot: plot).y(forPercentage: Double(percentage))))
                )
        }
        Text("25°C")
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .position(x: plot.minX + 12, y: size.height - 8)
        Text("100°C")
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .position(x: plot.maxX - 15, y: size.height - 8)
    }

    private var usesRPMAxis: Bool {
        FanCurveEditor.targetRPM(percentage: 0, fanReadings: fanReadings) != nil
    }

    private func axisLabel(percentage: Int) -> String {
        if let rpm = FanCurveEditor.targetRPM(
            percentage: Double(percentage), fanReadings: fanReadings
        ) {
            return String(rpm)
        }
        return "\(percentage)%"
    }

    private func curvePath(in plot: CGRect) -> Path {
        let transform = FanCurvePlotTransform(plot: plot)
        return Path { path in
            for (index, point) in points.enumerated() {
                let location = transform.position(for: point)
                index == 0 ? path.move(to: location) : path.addLine(to: location)
            }
        }
    }

    private func gridPath(in plot: CGRect) -> Path {
        Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                let y = plot.minY + plot.height * fraction
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            for fraction in [0.25, 0.5, 0.75] {
                let x = plot.minX + plot.width * fraction
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
            }
        }
    }
}
