import AppKit
import FanControlShared
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FanCurveEditorInteractionTests: XCTestCase {
    private let transform = FanCurvePlotTransform(
        plot: CGRect(x: 30, y: 10, width: 300, height: 160)
    )

    #if DEBUG || STORAGE_CLEANER_BETA
    func testDefaultCurveFixtureRemainsDraftAndTemperatureFollowsSelectedSourceWithoutSampling() throws {
        let suite = "FanCurveEditorInteractionTests.FixtureDraft.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = MiniWindowDemoData.hardwareControlProfile(for: .curveDefault)
        let snapshot = SystemMonitorSnapshot(generatedAt: Date(), metrics: [], networkThroughput: nil,
            fanReadings: profile.fanReadings,
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 51),
                SystemTemperatureReading(zone: .gpu, celsius: 72),
            ])
        let coordinator = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults, profile: profile, snapshot: snapshot)
        let store = coordinator.curveStore
        XCTAssertNil(store.appliedProfile, "A supplied default profile is an editable draft, not a confirmed applied curve")
        XCTAssertEqual(coordinator.observedMode, .systemAutomatic)
        let session = FanCurveEditorSession(profile: store.draftProfile, commitDraft: { _ = store.replaceDraft($0) })
        session.setSensor(.cpu, undoManager: nil)
        XCTAssertEqual(coordinator.previewTemperature(for: session.draftProfile.sensor), 51)
        session.setSensor(.gpu, undoManager: nil)
        XCTAssertEqual(coordinator.previewTemperature(for: session.draftProfile.sensor), 72)
        XCTAssertNil(coordinator.previewTemperature(for: .efficiencyCore))
        session.updatePoint(id: session.points[0].id, temperatureCelsius: 41, speedFraction: 0.25, undoManager: nil)
        XCTAssertTrue(session.hasUnsavedChanges(comparedWith: store.savedProfile))
        session.discardChanges(to: store.savedProfile, undoManager: nil)
        XCTAssertFalse(session.hasUnsavedChanges(comparedWith: store.savedProfile))
        XCTAssertTrue(session.hasUnappliedChanges(comparedWith: store.appliedProfile))
        XCTAssertNil(store.appliedProfile)
        XCTAssertEqual(coordinator.observedMode, .systemAutomatic)
        XCTAssertNil(coordinator.requestedMode)
        XCTAssertFalse(coordinator.isApplying)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/FanCurveEditor.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("MiniWindowDemoData.hardwareControlProfile"))
        XCTAssertTrue(source.contains("session.hasUnappliedChanges(comparedWith: store.appliedProfile)"))
        XCTAssertTrue(source.contains("fanControl.previewTemperature(for: session.draftProfile.sensor)"))
        XCTAssertTrue(source.contains("guard canApply else { return }"))
    }
    #endif

    func testRPMAxisUsesReportedRangeAndPreservesStoppedFanReading() {
        let readings = [SystemFanReading(
            index: 0, actualRPM: 0, minimumRPM: 1_200, maximumRPM: 6_000, targetRPM: nil
        )]
        XCTAssertEqual(FanCurveEditor.targetRPM(percentage: 0, fanReadings: readings), 1_200)
        XCTAssertEqual(FanCurveEditor.targetRPM(percentage: 50, fanReadings: readings), 3_600)
        XCTAssertEqual(FanCurveEditor.targetRPM(percentage: 100, fanReadings: readings), 6_000)
        XCTAssertEqual(readings.first?.actualRPM, 0, "Target-axis labels must not replace actual telemetry")
    }

    func testRPMAxisAveragesIndividuallyRoundedFanTargets() throws {
        let readings = [
            SystemFanReading(index: 0, actualRPM: 1_600, minimumRPM: 1_000, maximumRPM: 5_001, targetRPM: nil),
            SystemFanReading(index: 1, actualRPM: 2_400, minimumRPM: 2_000, maximumRPM: 6_000, targetRPM: nil),
        ]
        let targets = try FanCurveRPMMapper.targets(percentage: 50, ranges: [
            FanCurveFanRange(fanID: 0, minimumRPM: 1_000, maximumRPM: 5_001, actualRPM: 1_600),
            FanCurveFanRange(fanID: 1, minimumRPM: 2_000, maximumRPM: 6_000, actualRPM: 2_400),
        ])
        XCTAssertEqual(targets, [0: 3_001, 1: 4_000])
        XCTAssertEqual(FanCurveEditor.targetRPM(percentage: 0, fanReadings: readings), 1_500)
        XCTAssertEqual(FanCurveEditor.targetRPM(percentage: 50, fanReadings: readings), 3_501)
        XCTAssertEqual(FanCurveEditor.targetRPM(percentage: 100, fanReadings: readings), 5_501)
    }

    func testRPMAxisRequiresCompleteValidRangesAndUniqueFanIdentities() {
        let valid = SystemFanReading(index: 0, actualRPM: 1_600, minimumRPM: 1_200, maximumRPM: 6_000, targetRPM: nil)
        let unavailable = SystemFanReading(index: 1, actualRPM: 2_000, minimumRPM: nil, maximumRPM: 6_000, targetRPM: nil)
        let invalid = SystemFanReading(index: 1, actualRPM: 2_000, minimumRPM: 6_000, maximumRPM: 6_000, targetRPM: nil)
        for readings in [[], [valid, unavailable], [valid, invalid], [valid, valid]] {
            XCTAssertNil(FanCurveEditor.targetRPM(percentage: 50, fanReadings: readings))
        }
        for percentage in [Double.nan, -1, 101] {
            XCTAssertNil(FanCurveEditor.targetRPM(percentage: percentage, fanReadings: [valid]))
        }
    }

    func testPlotTransformRoundTripsAndZeroTranslationDoesNotJump() throws {
        let point = FanCurvePoint(temperatureCelsius: 65, speedFraction: 0.55)
        let position = transform.position(for: point)
        let values = transform.values(at: position)
        let zeroTranslation = transform.translatedValues(from: point, translation: .zero)

        XCTAssertEqual(values.temperature, 65, accuracy: 0.000_1)
        XCTAssertEqual(values.speedFraction, 0.55, accuracy: 0.000_1)
        XCTAssertEqual(zeroTranslation.temperature, point.temperatureCelsius)
        XCTAssertEqual(zeroTranslation.speedFraction, point.speedFraction)
    }

    func testDragUsesContinuousLocalDraftThenNormalizesOnceAtEnd() throws {
        let profile = FanCurveProfile.balanced()
        let session = FanCurveEditorSession(profile: profile)
        let point = try XCTUnwrap(profile.points.dropFirst(2).first)

        session.beginDrag(pointID: point.id)
        session.updateDrag(
            pointID: point.id,
            translation: CGSize(width: 1, height: -1),
            transform: transform
        )

        let livePoint = try XCTUnwrap(session.points.first { $0.id == point.id })
        XCTAssertNotEqual(livePoint.temperatureCelsius, livePoint.temperatureCelsius.rounded())
        XCTAssertTrue(session.isDragging)

        XCTAssertTrue(session.endDrag(
            pointID: point.id,
            translation: CGSize(width: 21, height: -13),
            transform: transform,
            undoManager: nil
        ))
        let finalPoint = try XCTUnwrap(session.points.first { $0.id == point.id })
        XCTAssertEqual(finalPoint.temperatureCelsius, finalPoint.temperatureCelsius.rounded())
        XCTAssertEqual(
            finalPoint.fanPercentage,
            finalPoint.fanPercentage.rounded(),
            accuracy: 0.000_1
        )
        XCTAssertFalse(session.isDragging)
    }

    func testDragClampsWithoutSortingOrBreakingCurveRules() throws {
        let profile = FanCurveProfile.balanced()
        let originalIDs = profile.points.map(\.id)
        let session = FanCurveEditorSession(profile: profile)
        let middle = profile.points[2]

        session.beginDrag(pointID: middle.id)
        session.updateDrag(
            pointID: middle.id,
            translation: CGSize(width: -2_000, height: 2_000),
            transform: transform
        )
        _ = session.endDrag(
            pointID: middle.id,
            translation: CGSize(width: -2_000, height: 2_000),
            transform: transform,
            undoManager: nil
        )

        XCTAssertEqual(session.points.map(\.id), originalIDs)
        XCTAssertEqual(
            session.points[2].temperatureCelsius,
            session.points[1].temperatureCelsius + FanCurveProfile.minimumTemperatureGap
        )
        XCTAssertEqual(session.points[2].speedFraction, session.points[1].speedFraction)
        XCTAssertNoThrow(try FanCurveValidator.validate(session.draftProfile))

        let final = try XCTUnwrap(session.points.last)
        session.beginDrag(pointID: final.id)
        _ = session.endDrag(
            pointID: final.id,
            translation: CGSize(width: 2_000, height: 2_000),
            transform: transform,
            undoManager: nil
        )
        XCTAssertEqual(session.points.last?.temperatureCelsius, 90)
        XCTAssertEqual(session.points.last?.fanPercentage, 100)
    }

    func testOneCompleteDragCreatesOneUndoAndRedoStep() throws {
        let profile = FanCurveProfile.balanced()
        let session = FanCurveEditorSession(profile: profile)
        let undoManager = UndoManager()
        let point = profile.points[2]

        session.beginDrag(pointID: point.id)
        for offset in 1...80 {
            session.updateDrag(
                pointID: point.id,
                translation: CGSize(
                    width: CGFloat(offset),
                    height: -CGFloat(offset) / 3
                ),
                transform: transform
            )
        }
        XCTAssertTrue(session.endDrag(
            pointID: point.id,
            translation: CGSize(width: 80, height: -26),
            transform: transform,
            undoManager: undoManager
        ))
        let dragged = session.draftProfile

        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertTrue(session.draftProfile.hasSameControlDefinition(as: profile))
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertTrue(session.draftProfile.hasSameControlDefinition(as: dragged))
    }

    func testAddDeleteAndRestoreDefaultEachSupportUndo() throws {
        var profile = FanCurveProfile.balanced()
        profile.points[0].speedFraction = 0.25
        let session = FanCurveEditorSession(profile: profile)
        let undoManager = UndoManager()

        let addedID = try XCTUnwrap(session.addPoint(undoManager: undoManager))
        XCTAssertEqual(session.selectedPointID, addedID)
        XCTAssertEqual(session.points.count, 6)
        undoManager.undo()
        XCTAssertEqual(session.points.count, 5)

        let removableID = try XCTUnwrap(session.points.first?.id)
        session.removePoint(id: removableID, undoManager: undoManager)
        XCTAssertEqual(session.points.count, 4)
        undoManager.undo()
        XCTAssertEqual(session.points.count, 5)

        session.restoreDefault(undoManager: undoManager)
        XCTAssertEqual(session.points.first?.fanPercentage, 20)
        undoManager.undo()
        XCTAssertEqual(session.points.first?.fanPercentage, 25)
    }

    func testDragDoesNotTouchStorePersistenceUntilExplicitCommit() throws {
        let suite = "FanCurveEditorInteractionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FanCurveStore(defaults: defaults)
        let original = store.draftProfile
        let originalDefaultKeys = Set(defaults.dictionaryRepresentation().keys)
        let originalDraftData = defaults.data(forKey: "fanCurve.draftProfile.v1")
        let session = FanCurveEditorSession(profile: original)
        let point = original.points[2]

        session.beginDrag(pointID: point.id)
        for offset in 0..<500 {
            session.updateDrag(
                pointID: point.id,
                translation: CGSize(
                    width: CGFloat(offset % 90),
                    height: -CGFloat(offset % 45)
                ),
                transform: transform
            )
        }

        XCTAssertTrue(store.draftProfile.hasSameControlDefinition(as: original))
        XCTAssertEqual(Set(defaults.dictionaryRepresentation().keys), originalDefaultKeys)
        XCTAssertEqual(defaults.data(forKey: "fanCurve.draftProfile.v1"), originalDraftData)

        _ = session.endDrag(
            pointID: point.id,
            translation: CGSize(width: 60, height: -20),
            transform: transform,
            undoManager: nil
        )
        XCTAssertTrue(store.draftProfile.hasSameControlDefinition(as: original))
        XCTAssertTrue(store.replaceDraft(session.draftProfile))
        XCTAssertFalse(store.draftProfile.hasSameControlDefinition(as: original))
    }

    func testOneDragCommitsExactlyOnceAfterItEnds() throws {
        let profile = FanCurveProfile.balanced()
        var commits: [FanCurveProfile] = []
        let session = FanCurveEditorSession(
            profile: profile,
            commitDraft: { commits.append($0) }
        )
        let point = profile.points[2]

        session.beginDrag(pointID: point.id)
        for offset in 1...80 {
            session.updateDrag(
                pointID: point.id,
                translation: CGSize(width: CGFloat(offset), height: -CGFloat(offset) / 3),
                transform: transform
            )
        }
        XCTAssertTrue(commits.isEmpty)

        XCTAssertTrue(session.endDrag(
            pointID: point.id,
            translation: CGSize(width: 80, height: -26),
            transform: transform,
            undoManager: nil
        ))
        XCTAssertEqual(commits.count, 1)
        XCTAssertTrue(commits[0].hasSameControlDefinition(as: session.draftProfile))
    }

    func testDragPathHasNoXPCSMCPersistenceOrPanelDependency() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/FanCurveEditorSession.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let begin = try XCTUnwrap(source.range(of: "func beginDrag")).upperBound
        let end = try XCTUnwrap(source.range(of: "func addPoint", range: begin..<source.endIndex)).lowerBound
        let dragSource = String(source[begin..<end])

        for forbidden in ["UserDefaults", "FanControlCoordinator", "XPC", "SMC", "setFrame"] {
            XCTAssertFalse(dragSource.contains(forbidden), "Drag path must not reference \(forbidden)")
        }
    }

    func testFiveHundredLocalDragUpdatesStayWithinInteractiveBudget() throws {
        let profile = FanCurveProfile.balanced()
        let session = FanCurveEditorSession(profile: profile)
        let point = profile.points[2]
        let clock = ContinuousClock()
        let started = clock.now

        session.beginDrag(pointID: point.id)
        for offset in 0..<500 {
            session.updateDrag(
                pointID: point.id,
                translation: CGSize(
                    width: CGFloat(offset % 90),
                    height: -CGFloat(offset % 45)
                ),
                transform: transform
            )
        }
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(1))
    }
}
