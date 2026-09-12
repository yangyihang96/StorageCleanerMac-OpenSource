import AppKit
import Combine
import FanControlShared
import Foundation

struct FanCurvePlotTransform: Equatable {
    let plot: CGRect

    func x(for temperature: Double) -> CGFloat {
        let temperatureSpan = FanCurveProfile.temperatureRange.upperBound
            - FanCurveProfile.temperatureRange.lowerBound
        let fraction = (temperature - FanCurveProfile.temperatureRange.lowerBound)
            / temperatureSpan
        return plot.minX + plot.width * min(1, max(0, fraction))
    }

    func y(forPercentage percentage: Double) -> CGFloat {
        plot.maxY - plot.height * min(1, max(0, percentage / 100))
    }

    func position(for point: FanCurvePoint) -> CGPoint {
        return CGPoint(
            x: x(for: point.temperatureCelsius),
            y: plot.maxY - plot.height * min(1, max(0, point.speedFraction))
        )
    }

    func values(at location: CGPoint) -> (temperature: Double, speedFraction: Double) {
        let x = min(1, max(0, (location.x - plot.minX) / max(1, plot.width)))
        let y = min(1, max(0, (location.y - plot.minY) / max(1, plot.height)))
        let range = FanCurveProfile.temperatureRange
        return (
            range.lowerBound + Double(x) * (range.upperBound - range.lowerBound),
            1 - Double(y)
        )
    }

    func translatedValues(
        from point: FanCurvePoint,
        translation: CGSize
    ) -> (temperature: Double, speedFraction: Double) {
        let temperatureSpan = FanCurveProfile.temperatureRange.upperBound
            - FanCurveProfile.temperatureRange.lowerBound
        return (
            point.temperatureCelsius
                + Double(translation.width / max(1, plot.width)) * temperatureSpan,
            point.speedFraction - Double(translation.height / max(1, plot.height))
        )
    }
}

@MainActor
final class FanCurveEditorSession: ObservableObject {
    private struct Snapshot {
        let profile: FanCurveProfile
        let selectedPointID: UUID?
    }

    private struct DragState {
        let pointID: UUID
        let origin: Snapshot
        let originPoint: FanCurvePoint
    }

    @Published private(set) var draftProfile: FanCurveProfile
    @Published private(set) var selectedPointID: UUID?
    @Published private(set) var hoveredPointID: UUID?
    @Published private var dragState: DragState?

    private let now: () -> Date
    private let commitDraft: (FanCurveProfile) -> Void
    private var lastInstrumentedPoint: (temperature: Int, percentage: Int)?

    init(
        profile: FanCurveProfile,
        now: @escaping () -> Date = Date.init,
        commitDraft: @escaping (FanCurveProfile) -> Void = { _ in }
    ) {
        draftProfile = profile
        selectedPointID = profile.points.first?.id
        self.now = now
        self.commitDraft = commitDraft
    }

    var points: [FanCurvePoint] { draftProfile.points }
    var isDragging: Bool { dragState != nil }
    var draggingPointID: UUID? { dragState?.pointID }

    var selectedPoint: FanCurvePoint? {
        points.first { $0.id == selectedPointID } ?? points.first
    }

    var validationError: FanCurveError? {
        do {
            try FanCurveValidator.validate(draftProfile)
            return nil
        } catch let error as FanCurveError {
            return error
        } catch {
            return .curveActivationFailed
        }
    }

    func hasUnappliedChanges(comparedWith profile: FanCurveProfile?) -> Bool {
        !draftProfile.hasSameControlDefinition(as: profile)
    }

    func hasUnsavedChanges(comparedWith profile: FanCurveProfile) -> Bool {
        !draftProfile.hasSameControlDefinition(as: profile)
    }

    func synchronize(with profile: FanCurveProfile) {
        guard !isDragging,
              !draftProfile.hasSameControlDefinition(as: profile) else { return }
        draftProfile = profile
        if selectedPointID.map({ id in profile.points.contains { $0.id == id } }) != true {
            selectedPointID = profile.points.first?.id
        }
    }

    func select(_ id: UUID) {
        guard points.contains(where: { $0.id == id }) else { return }
        selectedPointID = id
    }

    func setHoveredPoint(_ id: UUID?) {
        hoveredPointID = id
    }

    func setSensor(_ sensor: FanCurveSensor, undoManager: UndoManager?) {
        var candidate = draftProfile
        candidate.sensor = sensor
        candidate.updatedAt = now()
        performChange(
            to: candidate,
            selectedPointID: selectedPointID,
            actionName: L10n.text("更改曲线温度来源", "Change Curve Temperature Source"),
            undoManager: undoManager
        )
    }

    func updatePoint(
        id: UUID,
        temperatureCelsius: Double,
        speedFraction: Double,
        undoManager: UndoManager?
    ) {
        guard var candidate = constrainedProfile(
            draftProfile,
            pointID: id,
            temperatureCelsius: temperatureCelsius,
            speedFraction: speedFraction,
            normalizesToWholeUnits: true
        ) else { return }
        candidate.updatedAt = now()
        performChange(
            to: candidate,
            selectedPointID: id,
            actionName: L10n.text("调整风扇曲线", "Adjust Fan Curve"),
            undoManager: undoManager
        )
    }

    func beginDrag(pointID: UUID) {
        guard dragState == nil,
              let point = points.first(where: { $0.id == pointID }) else { return }
        selectedPointID = pointID
        dragState = DragState(
            pointID: pointID,
            origin: snapshot,
            originPoint: point
        )
        lastInstrumentedPoint = instrumentedValues(for: point)
        PerformanceTelemetry.signposter.emitEvent("CurveDragStarted")
    }

    func updateDrag(
        pointID: UUID,
        translation: CGSize,
        transform: FanCurvePlotTransform
    ) {
        if dragState == nil { beginDrag(pointID: pointID) }
        guard let dragState, dragState.pointID == pointID else { return }
        let values = transform.translatedValues(
            from: dragState.originPoint,
            translation: translation
        )
        guard let candidate = constrainedProfile(
            dragState.origin.profile,
            pointID: pointID,
            temperatureCelsius: values.temperature,
            speedFraction: values.speedFraction,
            normalizesToWholeUnits: false
        ) else { return }
        draftProfile = candidate
        selectedPointID = pointID

        guard let point = candidate.points.first(where: { $0.id == pointID }) else { return }
        let instrumented = instrumentedValues(for: point)
        if lastInstrumentedPoint?.temperature != instrumented.temperature
            || lastInstrumentedPoint?.percentage != instrumented.percentage {
            lastInstrumentedPoint = instrumented
            PerformanceTelemetry.signposter.emitEvent("CurveDragUpdated")
            PerformanceTelemetry.signposter.emitEvent("DraftPreviewUpdated")
        }
    }

    @discardableResult
    func endDrag(
        pointID: UUID,
        translation: CGSize,
        transform: FanCurvePlotTransform,
        undoManager: UndoManager?
    ) -> Bool {
        updateDrag(pointID: pointID, translation: translation, transform: transform)
        guard let dragState, dragState.pointID == pointID,
              let current = draftProfile.points.first(where: { $0.id == pointID }),
              var normalized = constrainedProfile(
                  draftProfile,
                  pointID: pointID,
                  temperatureCelsius: current.temperatureCelsius,
                  speedFraction: current.speedFraction,
                  normalizesToWholeUnits: true
              ) else {
            self.dragState = nil
            return false
        }
        normalized.updatedAt = now()
        draftProfile = normalized
        self.dragState = nil
        lastInstrumentedPoint = nil
        PerformanceTelemetry.signposter.emitEvent("CurveDragEnded")

        let changed = !normalized.hasSameControlDefinition(as: dragState.origin.profile)
        if changed {
            registerUndo(
                restoring: dragState.origin,
                actionName: L10n.text("拖动风扇曲线控制点", "Drag Fan Curve Point"),
                undoManager: undoManager
            )
            commitDraft(normalized)
        }
        return changed
    }

    func cancelDrag() {
        guard let dragState else { return }
        restore(dragState.origin)
        self.dragState = nil
        lastInstrumentedPoint = nil
        PerformanceTelemetry.signposter.emitEvent("CurveDragEnded")
    }

    @discardableResult
    func addPoint(undoManager: UndoManager?) -> UUID? {
        let points = draftProfile.points
        guard points.count < FanCurveProfile.maximumPointCount else { return nil }
        let gaps = zip(points.indices, points.indices.dropFirst()).map { lower, upper in
            (
                lower: lower,
                upper: upper,
                gap: points[upper].temperatureCelsius - points[lower].temperatureCelsius
            )
        }
        guard let largest = gaps.max(by: { $0.gap < $1.gap }),
              largest.gap >= FanCurveProfile.minimumTemperatureGap * 2 else { return nil }
        let lower = points[largest.lower]
        let upper = points[largest.upper]
        let point = FanCurvePoint(
            temperatureCelsius: ((lower.temperatureCelsius + upper.temperatureCelsius) / 2).rounded(),
            speedFraction: ((lower.speedFraction + upper.speedFraction) / 2 * 100).rounded() / 100
        )
        var candidate = draftProfile
        candidate.points.insert(point, at: largest.upper)
        candidate.updatedAt = now()
        performChange(
            to: candidate,
            selectedPointID: point.id,
            actionName: L10n.text("增加风扇曲线控制点", "Add Fan Curve Point"),
            undoManager: undoManager
        )
        return point.id
    }

    func removePoint(id: UUID, undoManager: UndoManager?) {
        guard points.count > FanCurveProfile.minimumPointCount,
              let index = points.firstIndex(where: { $0.id == id }),
              index != points.indices.last else { return }
        var candidate = draftProfile
        candidate.points.remove(at: index)
        candidate.updatedAt = now()
        let nextSelection = candidate.points[min(index, candidate.points.count - 1)].id
        performChange(
            to: candidate,
            selectedPointID: nextSelection,
            actionName: L10n.text("删除风扇曲线控制点", "Delete Fan Curve Point"),
            undoManager: undoManager
        )
    }

    func restoreDefault(undoManager: UndoManager?) {
        var candidate = FanCurveProfile.balanced(
            targetFanIDs: draftProfile.targetFanIDs,
            now: now()
        )
        candidate.id = draftProfile.id
        candidate.name = draftProfile.name
        performChange(
            to: candidate,
            selectedPointID: candidate.points.first?.id,
            actionName: L10n.text("恢复默认风扇曲线", "Restore Default Fan Curve"),
            undoManager: undoManager
        )
    }

    func discardChanges(to profile: FanCurveProfile, undoManager: UndoManager?) {
        performChange(
            to: profile,
            selectedPointID: profile.points.first?.id,
            actionName: L10n.text("取消风扇曲线更改", "Discard Fan Curve Changes"),
            undoManager: undoManager
        )
    }

    private var snapshot: Snapshot {
        Snapshot(profile: draftProfile, selectedPointID: selectedPointID)
    }

    private func performChange(
        to profile: FanCurveProfile,
        selectedPointID: UUID?,
        actionName: String,
        undoManager: UndoManager?
    ) {
        guard !profile.hasSameControlDefinition(as: draftProfile) else {
            self.selectedPointID = selectedPointID
            return
        }
        let previous = snapshot
        draftProfile = profile
        self.selectedPointID = selectedPointID
        registerUndo(restoring: previous, actionName: actionName, undoManager: undoManager)
        commitDraft(profile)
    }

    private func registerUndo(
        restoring snapshot: Snapshot,
        actionName: String,
        undoManager: UndoManager?
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            let redo = target.snapshot
            target.restore(snapshot)
            target.commitDraft(snapshot.profile)
            target.registerUndo(
                restoring: redo,
                actionName: actionName,
                undoManager: undoManager
            )
        }
        undoManager?.setActionName(actionName)
    }

    private func restore(_ snapshot: Snapshot) {
        draftProfile = snapshot.profile
        selectedPointID = snapshot.selectedPointID
    }

    private func constrainedProfile(
        _ profile: FanCurveProfile,
        pointID: UUID,
        temperatureCelsius: Double,
        speedFraction: Double,
        normalizesToWholeUnits: Bool
    ) -> FanCurveProfile? {
        guard temperatureCelsius.isFinite,
              speedFraction.isFinite,
              let index = profile.points.firstIndex(where: { $0.id == pointID }) else {
            return nil
        }
        var candidate = profile
        let points = profile.points
        let isLast = index == points.indices.last
        let lowerTemperature = index > 0
            ? points[index - 1].temperatureCelsius + FanCurveProfile.minimumTemperatureGap
            : FanCurveProfile.temperatureRange.lowerBound
        let upperTemperature = isLast
            ? FanCurveProfile.latestFullSpeedTemperature
            : points[index + 1].temperatureCelsius - FanCurveProfile.minimumTemperatureGap
        let lowerFraction = index > 0 ? points[index - 1].speedFraction : 0
        let upperFraction = isLast ? 1 : points[index + 1].speedFraction
        let proposedTemperature = normalizesToWholeUnits
            ? temperatureCelsius.rounded()
            : temperatureCelsius
        let proposedFraction = normalizesToWholeUnits
            ? (speedFraction * 100).rounded() / 100
            : speedFraction
        candidate.points[index].temperatureCelsius = min(
            upperTemperature,
            max(lowerTemperature, proposedTemperature)
        )
        candidate.points[index].speedFraction = isLast
            ? 1
            : min(upperFraction, max(lowerFraction, proposedFraction))
        return candidate
    }

    private func instrumentedValues(
        for point: FanCurvePoint
    ) -> (temperature: Int, percentage: Int) {
        (
            Int(point.temperatureCelsius.rounded()),
            Int(point.fanPercentage.rounded())
        )
    }
}
