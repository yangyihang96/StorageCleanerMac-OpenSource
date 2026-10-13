#if DEBUG
import AppKit
import FanControlShared
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D67/D70/D72 own twelve Lightfield routes; two V1 routes retain D62/D63.
/// Native frames use the existing AppKit host and the unchanged 0.5 pt tolerance.
@MainActor
final class FeatureLightfieldContractTests: XCTestCase {
    private let windows: [CGSize] = [.init(width: 820, height: 560), .init(width: 1000, height: 700),
        .init(width: 1280, height: 763), .init(width: 1680, height: 1050), .init(width: 2400, height: 1350),
        .init(width: 677, height: 390), .init(width: 1280, height: 390)]

    func testProductionPilotsKeepNativeSkeletonAcrossThreeStatesSevenSizesAndTwoSchemes() async throws {
        var references: [String: [String: CGRect]] = [:]
        let skeleton = ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status"]
        for dark in [true, false] {
            for module in FeatureLightfield.pilots {
                for phase in FeaturePresentationDemo.Phase.allCases {
                    let host = CalibrationAppKitLayoutHost(root: try fixture(module: module, phase: phase),
                        size: CGSize(width: 1070, height: 735), dark: dark)
                    defer { host.close() }
                    for window in windows {
                        let canvas = CGSize(width: window.width - 210, height: window.height - 28)
                        host.resize(to: canvas)
                        let frames = try await host.frames(required: Set(skeleton + ["fixture.viewport"]), size: canvas)
                        let key = "\(dark)-\(window)-\(phase == .result)"
                        let primary = try XCTUnwrap(frames["lightfield.primary"])
                        let status = try XCTUnwrap(frames["lightfield.status"])
                        let content = try XCTUnwrap(frames["lightfield.content"])
                        let viewport = try XCTUnwrap(frames["fixture.viewport"])
                        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(primary))
                        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(status))
                        if phase == .result {
                            try assertCompactResultSkeleton(frames, window: window)
                        } else {
                            XCTAssertEqual(primary.height, 52, accuracy: 0.5)
                            XCTAssertEqual(status.height, 64, accuracy: 0.5)
                            XCTAssertEqual(primary.minY - content.maxY, 24, accuracy: 0.5)
                            XCTAssertEqual(status.minY - primary.maxY, 24, accuracy: 0.5)
                        }
                        if let reference = references[key] {
                            for id in skeleton {
                                let actual = try XCTUnwrap(frames[id]), expected = try XCTUnwrap(reference[id])
                                equal(actual.origin, expected.origin, "\(module)/\(phase)/\(window)/\(id)")
                                XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
                                if id != "lightfield.content" { XCTAssertEqual(actual.width, expected.width, accuracy: 0.5) }
                            }
                        } else { references[key] = frames }
                        if window == CGSize(width: 1280, height: 763) {
                            if phase == .result {
                                let art = try await host.frames(required: ["lightfield.artwork"], size: canvas)
                                XCTAssertEqual(try XCTUnwrap(art["lightfield.artwork"]), CGRect(x: 24, y: 16, width: 40, height: 40))
                                continue
                            }
                            equal(primary.origin, CGPoint(x: 96, y: 595), "Independent D67 primary anchor")
                            XCTAssertEqual(primary.width, 520, accuracy: 0.5)
                            equal(try XCTUnwrap(frames["lightfield.title"]).origin, CGPoint(x: 96, y: 92), "Title")
                            equal(content.origin, CGPoint(x: 96, y: 176), "Content")
                            XCTAssertEqual(content.height, 395, accuracy: 0.5)
                            XCTAssertEqual(content.width, phase == .result ? 878 : 520, accuracy: 0.5)
                            equal(status.origin, CGPoint(x: 52, y: 671), "Status")
                            XCTAssertEqual(status.width, 966, accuracy: 0.5)
                            let line = try await host.frames(required: ["lightfield.status.divider",
                                "lightfield.status.safety", "fixture.viewport"], size: canvas)
                            let divider = try XCTUnwrap(line["lightfield.status.divider"])
                            let safety = try XCTUnwrap(line["lightfield.status.safety"])
                            XCTAssertEqual(safety.minX - divider.maxX, 20, accuracy: 0.5, "Divider precedes the safety line")
                            XCTAssertEqual(safety.maxX, status.maxX, accuracy: 0.5)
                            let art = try await host.frames(required: ["lightfield.artwork", "fixture.viewport"], size: canvas)
                            let image = try XCTUnwrap(art["lightfield.artwork"])
                            equal(image.origin, phase == .result ? CGPoint(x: 96, y: 176) : CGPoint(x: 610, y: 150), "Artwork")
                            XCTAssertEqual(image.width, phase == .result ? 76 : 360, accuracy: 0.5)
                            XCTAssertEqual(image.height, image.width, accuracy: 0.5)
                        }
                    }
                }
            }
        }
    }

    func testResultLongListUsesFullViewportShowsTenRowsAndLastItemIsReachable() async throws {
        for window in [CGSize(width: 1280, height: 763), CGSize(width: 677, height: 390)] {
            let size = CGSize(width: window.width - 210, height: window.height - 28)
            let host = CalibrationAppKitLayoutHost(root: try fixture(module: .uninstall, phase: .result), size: size, dark: false)
            defer { host.close() }
            let ids: Set<String> = ["lightfield.content", "lightfield.primary", "lightfield.results.scrollViewport", "lightfield.results.fade", "fixture.viewport"]
            let frames = try await host.frames(required: ids, size: size)
            let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
            let fade = try XCTUnwrap(frames["lightfield.results.fade"])
            let content = try XCTUnwrap(frames["lightfield.content"])
            let primary = try XCTUnwrap(frames["lightfield.primary"])
            XCTAssertGreaterThan(viewport.height, 0)
            XCTAssertEqual(fade.height, min(24, viewport.height), accuracy: 0.5)
            XCTAssertEqual(fade.maxY, viewport.maxY, accuracy: 0.5)
            XCTAssertLessThanOrEqual(viewport.maxY, content.maxY + 0.5)
            XCTAssertNil(frames["lightfield.results.scrollHint"])
            XCTAssertEqual(viewport.maxY, content.maxY, accuracy: 0.5)
            XCTAssertEqual(primary.minY - content.maxY, 16, accuracy: 0.5)
            if window.height == 763 {
                let rows = frames.filter { $0.key.hasPrefix("lightfield.uninstall.row.")
                    && viewport.insetBy(dx: -0.5, dy: -0.5).contains($0.value) }
                XCTAssertGreaterThanOrEqual(rows.count, 10, "D77 replaces the old five-row snapped viewport")
            }
            try host.scrollOptionsToBottom(matching: viewport)
            let after = try await host.frames(required: ["lightfield.uninstall.row.35", "lightfield.primary",
                "lightfield.results.scrollViewport", "fixture.viewport"], size: size)
            let last = try XCTUnwrap(after["lightfield.uninstall.row.35"])
            // Full viewport and pinned controls do not move while scrolling.
            XCTAssertEqual(try XCTUnwrap(after["lightfield.results.scrollViewport"]).height, viewport.height, accuracy: 0.5,
                "The list end must not move while scrolling")
            XCTAssertGreaterThan(last.maxY, viewport.minY - 0.5)
            XCTAssertLessThanOrEqual(last.maxY, viewport.maxY + 0.5)
            equal(try XCTUnwrap(after["lightfield.primary"]).origin, primary.origin, "Pinned after scroll")
        }
    }

    func testVisibleRuntimeStateSubtitleCurrentItemMetricsAndUnknownProgressAreAccessible() async throws {
        for state in [RuntimeWorkflowState.paused, .attention, .failed, .stopping, .cancelled] {
            let root = AdaptivePageViewport(resetID: .healthHub) { FeatureLightfieldPage(module: .healthHub, phase: .running, title: "Fixture",
                status: state.title, safety: "Read only", actionTitle: "Cancel", actionEnabled: false, action: {}) {
                FeatureLightfieldProgress(module: .healthHub, state: state, title: "Stage", subtitle: "Supplied subtitle",
                    fraction: nil, currentItem: "/Fixture/current", metrics: [.init(title: "Count", value: "3 / 4")],
                    elapsed: "Elapsed 12s", details: { Text("Supplied detail") }, actions: { Text("Supplied action") })
            } }.environment(\.featureDisablesLayoutAnimations, true)
            let size = CGSize(width: 1070, height: 735)
            let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
            defer { host.close() }
            let unknown = try await host.frames(required: ["runtime.stage", "runtime.progress", LayoutProbeID.runtimeLocation, "runtime.elapsed", "fixture.viewport"], size: size)
            XCTAssertNil(unknown["lightfield.progress.unit"], "Unknown progress must not show a % unit after the dash")
            try await host.waitForAccessibility(labels: [state.title + " · Stage", "Supplied subtitle", "/Fixture/current",
                "Count · 3 / 4", "Elapsed 12s", "Supplied detail", "Supplied action", L10n.text("进度", "Progress")],
                expectedValues: [L10n.text("进度", "Progress"): L10n.text("未提供进度", "Progress unavailable"),
                    state.title + " · Stage": "Elapsed 12s"])
        }
        let source = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift")
        XCTAssertTrue(source.contains("Text(state == .running ? title : state.title + \" · \" + title)"))
        XCTAssertTrue(source.contains("if let subtitle, !subtitle.isEmpty {"))
        XCTAssertTrue(source.contains("Text(subtitle).font(.system(size: 13))"))
        XCTAssertTrue(source.contains("Text(measured.map { String(Int($0 * 100)) } ?? \"—\")"))
        XCTAssertTrue(source.contains("ForEach(visibleMetrics)"))
        XCTAssertTrue(source.contains("Text(elapsed)"))
        XCTAssertTrue(source.contains("let active = phase == .running && !reduceMotion && !disablesAnimations && scenePhase == .active"))
        let viewportSource = try text("Sources/StorageCleanerMac/Views/ModulePresentation.swift")
        XCTAssertTrue(viewportSource.contains("resetID.map(FeatureLightfield.owns) == true"))
    }

    func testFullSizeBackdropAndCenteredHaloCoverThePilotCanvas() async throws {
        let page = MainContentHost(route: .green, showsIntegratedTitlebar: false) {
            FeatureLightfieldPage(module: .green, phase: .running, title: "Fixture", status: "Running",
                safety: "Read only", actionTitle: "Cancel", action: {}) { Text("Fixture content") }
        }.environment(\.featureDisablesLayoutAnimations, true)
        let size = CGSize(width: 1070, height: 735)
        let host = CalibrationAppKitLayoutHost(root: page, size: size, dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.backdrop", "lightfield.canvas",
            "lightfield.artwork", "lightfield.halo", "fixture.viewport"], size: size)
        let backdrop = try XCTUnwrap(frames["lightfield.backdrop"])
        let canvas = try XCTUnwrap(frames["lightfield.canvas"])
        let artwork = try XCTUnwrap(frames["lightfield.artwork"])
        let halo = try XCTUnwrap(frames["lightfield.halo"])
        XCTAssertLessThanOrEqual(backdrop.minY, canvas.minY + 0.5)
        XCTAssertGreaterThanOrEqual(backdrop.maxY, canvas.maxY - 0.5)
        XCTAssertEqual(halo.width, 640, accuracy: 0.5)
        XCTAssertEqual(halo.height, 640, accuracy: 0.5)
        let geometry = FeatureLightfieldGeometry(size: size, phase: .running)
        XCTAssertEqual(geometry.halo.midX, geometry.artwork.midX, accuracy: 0.5)
        XCTAssertEqual(geometry.halo.midY, geometry.artwork.midY, accuracy: 0.5)
        XCTAssertEqual(artwork.width, geometry.artwork.width, accuracy: 0.5)
        XCTAssertEqual(FeatureLightfield.haloCenterOpacity * FeatureLightfieldPalette.night.glow, 0.55)
        XCTAssertEqual(FeatureLightfield.haloCenterOpacity * FeatureLightfieldPalette.day.glow, 0.32)
        for short in [CGSize(width: 473, height: 360), CGSize(width: 1070, height: 362)] {
            let layout = FeatureLightfieldGeometry(size: short, phase: .running)
            XCTAssertGreaterThan(layout.content.height, 80)
            XCTAssertFalse(layout.artwork.intersects(layout.primary))
        }
        let source = try text("Sources/StorageCleanerMac/Views/ModulePresentation.swift")
        XCTAssertTrue(source.contains("FeatureLightfieldBackdrop(module: route, phase: lightfieldPhase"))
        let chrome = try XCTUnwrap(source.range(of: "FeatureLightfieldBackdrop(module: route, phase: lightfieldPhase"))
        let fallback = try XCTUnwrap(source.range(of: "} else {\n                ModuleBackground(theme: theme)", range: chrome.upperBound..<source.endIndex))
        XCTAssertTrue(source[chrome.lowerBound..<fallback.lowerBound].contains(".ignoresSafeArea(.container, edges: .top)"))
    }

    func testRunningFactsKeepLongCurrentItemOnOneLineAndExposeAuxiliaryMetric() async throws {
        let path = "/Fixture/" + String(repeating: "very-long-folder/", count: 24) + "sample.dat"
        let root = AdaptivePageViewport(resetID: .green) {
            FeatureLightfieldPage(module: .green, phase: .running, title: "Fixture", status: "Running",
                safety: "Read only", actionTitle: "Cancel", action: {}) {
                FeatureLightfieldProgress(module: .green, state: .running, title: "Current stage", subtitle: nil,
                    fraction: 0.6, currentItem: path,
                    metrics: [.init(title: "Found", value: "128"), .init(title: "Candidate size", value: "2.2 GiB"),
                        .init(title: "Steps", value: "3 / 4")], elapsed: "Elapsed 12s",
                    details: { EmptyView() }, actions: { EmptyView() })
            }
        }.environment(\.featureDisablesLayoutAnimations, true)
        let size = CGSize(width: 1070, height: 735)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: false)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.content", LayoutProbeID.runtimeLocation,
            "lightfield.progress.unit", "fixture.viewport"], size: size)
        let panel = try XCTUnwrap(frames["lightfield.content"])
        let location = try XCTUnwrap(frames[LayoutProbeID.runtimeLocation])
        XCTAssertLessThanOrEqual(location.width, panel.width + 0.5)
        XCTAssertGreaterThanOrEqual(location.height, 15)
        XCTAssertLessThanOrEqual(location.height, 24)
        // The stage element's spoken label is RuntimeWorkflowState.title + stage
        // ("In Progress · …"/"进行中 · …"), not the page status string "Running".
        let stage = RuntimeWorkflowState.running.title + " · Current stage"
        try await host.waitForAccessibility(labels: [stage, path, "Found · 128", "Steps · 3 / 4"],
            expectedValues: [stage: "Candidate size · 2.2 GiB, Elapsed 12s"])
        XCTAssertNil(host.element(label: "Candidate size · 2.2 GiB"), "Extra metric belongs to the stage's spoken value")
        let compact = CGSize(width: 467, height: 362)
        host.resize(to: compact)
        _ = try await host.frames(required: ["lightfield.progress.viewport", "fixture.viewport"], size: compact)
        try await host.waitForAccessibility(labels: [stage])
        let spoken = try XCTUnwrap(host.accessibilityValue(label: stage))
        for part in [path, "Found · 128", "Candidate size · 2.2 GiB", "Steps · 3 / 4"] {
            XCTAssertTrue(spoken.contains(part), part)
        }
        let scan = try text("Sources/StorageCleanerMac/Views/SmartScanProgressView.swift")
        XCTAssertTrue(scan.contains("if module != .green {"))
        let running = try text("Sources/StorageCleanerMac/Views/FeatureRunningPages.swift")
        XCTAssertTrue(running.contains("switch availability"))
        XCTAssertTrue(running.contains("subtitle: statusSubtitle"))
        let template = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift")
        let progressStart = try XCTUnwrap(template.range(of: "struct FeatureLightfieldProgress<"))
        let progressEnd = try XCTUnwrap(template.range(of: "struct FeatureLightfieldResults<", range: progressStart.upperBound..<template.endIndex))
        let progressSource = template[progressStart.lowerBound..<progressEnd.lowerBound]
        XCTAssertTrue(progressSource.contains("ViewThatFits(in: .vertical)"))
        XCTAssertTrue(progressSource.contains("showsOverflowHint: false"))
        XCTAssertTrue(progressSource.contains(".lineLimit(1).truncationMode(.middle).help(currentItem ?? \"\")"))
    }

    func testHealthStatusColumnAndEndDisclosureMatchSelectionColumn() async throws {
        let size = CGSize(width: 1070, height: 735)
        let health = CalibrationAppKitLayoutHost(root: FeatureLightfieldResultFixture(module: .healthHub), size: size, dark: true)
        defer { health.close() }
        let green = CalibrationAppKitLayoutHost(root: FeatureLightfieldResultFixture(module: .green), size: size, dark: true)
        defer { green.close() }
        let healthFrames = try await health.frames(required: ["lightfield.health.leading.diskReliability",
            "lightfield.health.disclosure.diskReliability", "fixture.viewport"], size: size)
        let greenFrames = try await green.frames(required: ["lightfield.green.leading", "fixture.viewport"], size: size)
        let leading = try XCTUnwrap(healthFrames["lightfield.health.leading.diskReliability"])
        let disclosure = try XCTUnwrap(healthFrames["lightfield.health.disclosure.diskReliability"])
        let selection = try XCTUnwrap(greenFrames["lightfield.green.leading"])
        XCTAssertEqual(leading.minX, selection.minX, accuracy: 0.5)
        XCTAssertGreaterThan(disclosure.minX, leading.maxX + 100)
        // The row-end arrow lives in a reserved column inside the row grid, so a
        // status row without details keeps the same value column and hairline.
        let factorValue = "lightfield.value." + HealthDashboardVisuals.factorTitle(.diskReliability)
        let plainValue = "lightfield.value." + L10n.text("时间机器", "Time Machine")
        let values = try await health.frames(required: [factorValue, plainValue, "fixture.viewport"], size: size)
        XCTAssertEqual(try XCTUnwrap(values[factorValue]).maxX, try XCTUnwrap(values[plainValue]).maxX, accuracy: 0.5)
        XCTAssertGreaterThan(disclosure.minX, try XCTUnwrap(values[factorValue]).maxX)
        let title = HealthDashboardVisuals.factorTitle(.diskReliability)
        let row = CalibrationAppKitLayoutHost(root: HealthFactorGrid(evaluation: FeatureLightfieldResultFixture.evaluation,
            snapshot: FeatureLightfieldResultFixture.healthSnapshot), size: CGSize(width: 878, height: 330), dark: true)
        defer { row.close() }
        let label = title + " · " + L10n.text("故障警告", "Failure")
        try await row.waitForAccessibility(labels: [label], expectedValues: [label: L10n.text("已折叠", "Collapsed")],
            pressLabels: [label])
        XCTAssertTrue(try row.press(label: label))
        try await row.waitForAccessibility(labels: [label], expectedValues: [label: L10n.text("已展开", "Expanded")])
        try await row.waitForAccessibility(labels: [HealthDashboardVisuals.availabilityText(.available) + " · 100 / 100"])
    }

    func testMotionTableAndInstantBranchMatchD67() {
        let actual: [Double] = [FeatureLightfieldMotion.press, FeatureLightfieldMotion.layerFade, FeatureLightfieldMotion.layerMove,
            FeatureLightfieldMotion.completion, FeatureLightfieldMotion.row, FeatureLightfieldMotion.rowInterval,
            FeatureLightfieldMotion.rowDelay, FeatureLightfieldMotion.number, FeatureLightfieldMotion.check,
            FeatureLightfieldMotion.title, FeatureLightfieldMotion.artworkFade, FeatureLightfieldMotion.artworkScale,
            FeatureLightfieldMotion.color, FeatureLightfieldMotion.halo, FeatureLightfieldMotion.float]
        XCTAssertEqual(actual, [0.120, 0.240, 0.260, 0.560, 0.300, 0.040, 0.380, 0.640, 0.160, 0.180, 0.260, 0.320, 0.300, 1.800, 2.400])
        XCTAssertEqual(FeatureLightfieldMotion.curve, [0.2, 0.8, 0.2, 1])
        XCTAssertEqual(FeatureLightfieldMotion.checkCurve, [0.3, 1.6, 0.5, 1])
        XCTAssertEqual(FeatureLightfieldMotion.pressScale, 0.985)
        XCTAssertEqual(FeatureLightfieldMotion.layerDistance, 10)
        XCTAssertEqual(FeatureLightfieldMotion.rowDistance, 8)
        XCTAssertEqual(FeatureLightfieldMotion.artworkSwapScale, 0.94)
        XCTAssertEqual(FeatureLightfieldMotion.haloOpacity, 0.25)
        XCTAssertEqual(FeatureLightfieldMotion.haloScale, 1.06)
        XCTAssertEqual(FeatureLightfieldMotion.floatDistance, 6)
        for time in actual {
            XCTAssertEqual(FeatureLightfieldMotion.duration(time, reduceMotion: true), 0)
            XCTAssertEqual(FeatureLightfieldMotion.duration(time, reduceMotion: false), time)
            XCTAssertNil(FeatureLightfieldMotion.animation(time, reduceMotion: true))
        }
        XCTAssertNil(FeatureLightfieldMotion.rowAnimation(index: 35, reduceMotion: true))
        XCTAssertNil(FeatureLightfieldMotion.checkAnimation(reduceMotion: true))
    }

    func testNightDayTokensAccentsAndSemanticSMARTWarningAreExact() {
        let night = FeatureLightfieldPalette.night, day = FeatureLightfieldPalette.day
        XCTAssertEqual(night.canvas, [0x141B44, 0x0B1230, 0x070B1D]); XCTAssertEqual(day.canvas, [0xE2EAF6, 0xEEF3FB, 0xF6F8FC])
        XCTAssertEqual(night.foreground, [0xF2F5FF, 0xA8B2CC, 0x6F7A96]); XCTAssertEqual(day.foreground, [0x121A33, 0x4F5B78, 0x7E889F])
        XCTAssertEqual(night.sidebar, 0x0A0F24); XCTAssertEqual(day.sidebar, 0xE8EEF8)
        XCTAssertEqual(night.sidebarLine, 0.06); XCTAssertEqual(day.sidebarLine, 0.08)
        XCTAssertEqual(night.hair, 0xBAC8FF); XCTAssertEqual(day.hair, 0x162850)
        XCTAssertEqual(night.hover, 0xFFFFFF); XCTAssertEqual(day.hover, 0x162850)
        XCTAssertEqual(night.star, 0xD2DCFF); XCTAssertEqual(day.star, 0x4664B4)
        XCTAssertEqual(night.starOpacity, 0.55); XCTAssertEqual(day.starOpacity, 0.18)
        XCTAssertEqual(night.glow, 0.55); XCTAssertEqual(day.glow, 0.32)
        XCTAssertEqual([night.normal, night.warning, night.failure], [0x3CCF86, 0xFFB340, 0xFF5D6C])
        XCTAssertEqual([day.normal, day.warning, day.failure], [0x1D9B5C, 0xC77700, 0xD23A4A])
        XCTAssertEqual(FeatureLightfield.starCount, 90)
        XCTAssertEqual(FeatureLightfieldPalette.accents(.green), [0xFF7A2F, 0xC4441A])
        XCTAssertEqual(FeatureLightfieldPalette.accents(.healthHub), [0x34C77B, 0x1E9E5A])
        XCTAssertEqual(FeatureLightfieldPalette.accents(.uninstall), [0xA07BFF, 0x5B3FD9])
        for (module, colors) in [(ReviewFilter.overview, [UInt32(0x4F8BFF), 0x2A55D6]),
            (.devCaches, [0xFFB340, 0xC46A0C]), (.privacy, [0x2FBF71, 0x168A55]),
            (.memory, [0x8B6CFF, 0x5B3FD9]), (.duplicates, [0x2CC9D6, 0x0E7C8C])] {
            XCTAssertEqual(FeatureLightfieldPalette.accents(module), colors)
        }
        let component = HealthComponentEvaluation(factor: .diskReliability, availability: .available,
            score: 100, evaluatedAt: MiniWindowDemoData.referenceDate, modelVersion: "fixture")
        XCTAssertEqual(HealthFactorGrid.lightfieldStatus(factor: .diskReliability, component: component, smart: .failing), .warning)
        XCTAssertEqual(HealthFactorGrid.lightfieldStatus(factor: .diskReliability, component: nil, smart: .unavailable), .unknown)
        XCTAssertNil(FeatureLightfieldAmount.parse("未提供").value)
        XCTAssertEqual(FeatureLightfieldAmount.parse("At least 12.2 GiB"), .init(value: 12.2, unit: "GiB", precision: 1, qualifier: "At least"))
    }

    func testNewTemplatePilotAdaptersCompatibilityAndSafetyHaveNoDecorativeContainers() throws {
        let template = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift")
        for token in [".glassPanel(", ".ultraThinMaterial", ".regularMaterial", "SurfaceBackground(", "IconTile(", "ContentPanel(", "AppPageHeader("] {
            XCTAssertFalse(template.contains(token), token)
        }
        for path in ["Views/AppUninstallScanLandingView.swift", "Views/ComputerHealth/ComputerHealthWorkspaceView.swift",
                     "Views/ComputerHealth/HealthFactorGrid.swift", "Views/ComputerHealth/HealthActionList.swift", "Views/ComputerHealthView.swift"] {
            let source = try text("Sources/StorageCleanerMac/" + path)
            for token in [".glassPanel(", ".ultraThinMaterial", "SurfaceBackground(", "IconTile(", "MetadataPill("] { XCTAssertFalse(source.contains(token), path + token) }
        }
        for contract in ["Text(title).font(.system(size: compactResult ? 20 : 34, weight: .bold)).tracking(0.34)",
            "font(.system(size: 64, weight: .bold))", "font(.system(size: 52, weight: .bold))",
            "font(.system(size: 24, weight: .semibold))", "font(.system(size: compact ? 13 : 17, weight: .semibold))",
            "Text(title).font(.system(size: 16))", "font(.system(size: 12.5, design: .monospaced))",
            ".frame(height: 56).contentShape(Rectangle())", "let numberWidth: CGFloat = compact ? 72 : 96",
            "remaining * 1.2 / 3.2", "remaining * 2 / 3.2", ".padding(.leading, 96)",
            "minHeight: 76, maxHeight: 76", "frame(height: 4).padding(.top, 22)"] {
            XCTAssertTrue(template.contains(contract), contract)
        }
        let sharedResults = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift")
        XCTAssertTrue(sharedResults.contains("VStack(spacing: 20)"), "D67 shared summary/list gap")
        // The primary inset highlight follows the rounded shape (no flat bar past the corners).
        XCTAssertFalse(template.contains(".frame(height: 2).clipShape(shape)"))
        XCTAssertTrue(template.contains(".init(color: .clear, location: 0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)"))
        let reference = FeatureLightfieldGeometry(size: CGSize(width: 1070, height: 735), phase: .landing)
        let result = FeatureLightfieldGeometry(size: CGSize(width: 1070, height: 735), phase: .result)
        XCTAssertEqual(reference.halo, CGRect(x: 470, y: 10, width: 640, height: 640))
        XCTAssertEqual(result.halo, CGRect(x: -120, y: 60, width: 420, height: 420))
        XCTAssertTrue(template.contains("phase == .result ? palette.glow * 0.6 : palette.glow"))
        let navigation = try text("Sources/StorageCleanerMac/Views/SidebarView.swift")
        XCTAssertTrue(navigation.contains("FeatureLightfieldArtwork(art:"))
        XCTAssertTrue(navigation.contains(".frame(width: 20, height: 20)"))
        let uninstaller = try text("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        XCTAssertFalse(uninstaller.contains(".onChange(of: selectedApplicationID)"), "Selection never opens the preview")
        XCTAssertTrue(uninstaller.contains("UninstallPreviewSheet(store: store, app: app)"))
        XCTAssertTrue(uninstaller.contains("copyPath: { store.copyPath($0.path) }, reveal: { store.reveal($0.path) }"))
        let list = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldUninstallList.swift")
        XCTAssertTrue(list.contains("LazyVStack(spacing: 0)"))
        XCTAssertTrue(list.contains(".onMoveCommand"))
        XCTAssertTrue(list.contains(".lightfieldRowEntrance(index)"))
        XCTAssertFalse(list.contains("confirmUninstall("))
        XCTAssertTrue(template.contains(".modifier(FeatureLightfieldArtworkMatch(namespace: flowNamespace))"))
        XCTAssertTrue(template.contains("id: \"lightfield.halo\""))
        XCTAssertTrue(template.contains(".animation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.completion"))
        XCTAssertTrue(template.contains(".lightfieldFrame(geometry.content, probe: \"lightfield.content\")"))
        let cleanup = try text("Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        let start = try XCTUnwrap(cleanup.range(of: "private var lightfieldResults: some View"))
        let end = try XCTUnwrap(cleanup.range(of: "private static let topAnchorID", range: start.upperBound..<cleanup.endIndex))
        let pilot = String(cleanup[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(pilot.contains("secondaryDetailsSection"))
        XCTAssertFalse(pilot.contains(".glassPanel("))
        XCTAssertTrue(pilot.contains("store.requestV2Cleanup(disposition: .trash, candidateIDs: selectionScopeIDs)"))
        XCTAssertTrue(pilot.contains("store.canRequestV2Cleanup"))
        XCTAssertTrue(pilot.contains("session.outcome != .cancelled"))
        XCTAssertTrue(pilot.contains("永久删除"))
        XCTAssertTrue(pilot.contains("store.setCleanupCandidates(ids, selected: state != .checked)"))
        // D67 selection rows keep the check box in the first column; the
        // subcategory disclosure is a row-end control inside the row grid.
        XCTAssertTrue(pilot.contains("reservesTrailing: true"))
        XCTAssertTrue(pilot.contains("FeatureLightfieldDisclosureChevron(expanded: expanded)"))
        XCTAssertFalse(pilot.contains("DisclosureGroup {\n            ForEach(sortedCandidates(in: subcategory))"))
        let templates = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureTemplates.swift")
        XCTAssertTrue(templates.contains("if FeatureLightfield.owns(module)"))
        XCTAssertTrue(templates.contains("FeaturePageScaffold("))
        // D69/D70: B3 performance, B4 updater, B5 privacy and B7 file routes
        // join the original pilots. Lock both exact route sets and counts.
        XCTAssertEqual(Set(FeaturePresentationDemo.modules.filter { FeatureLightfield.owns($0) }),
            Set([ReviewFilter.green, .healthHub, .uninstall, .startup, .memory, .energy,
                 .privacy, .updater, .largeFiles, .migration, .duplicates, .performance]))
        XCTAssertEqual(FeaturePresentationDemo.modules.filter { FeatureLightfield.owns($0) }.count, 12)
        XCTAssertEqual(Set(FeaturePresentationDemo.modules.filter { !FeatureLightfield.owns($0) }),
            Set([ReviewFilter.overview, .devCaches]))
        XCTAssertEqual(FeaturePresentationDemo.modules.filter { !FeatureLightfield.owns($0) }.count, 2)
        XCTAssertTrue(FeatureLightfield.owns(.performance)) // D72 v11 joins the integrated routes.
        let actions = try text("Sources/StorageCleanerMac/Views/ComputerHealth/HealthActionList.swift")
        XCTAssertFalse(actions.contains("留意电池"))
        // The battery title is inserted at runtime; the source cannot contain
        // the fully rendered phrase as a literal.
        XCTAssertTrue(actions.contains("HealthDashboardVisuals.factorTitle(action.factor))建议复核"))
    }

    func testResultFixtureIsDebugOnlyAndCannotInvokeProvidersOrOperations() throws {
        let source = try text("Sources/StorageCleanerMac/Debug/FeatureLightfieldResultFixture.swift")
        XCTAssertTrue(source.hasPrefix("#if DEBUG\n")); XCTAssertTrue(source.hasSuffix("#endif\n"))
        for token in ["ScanStore(", "FileManager.", "Process(", "requestUninstall(", "confirmUninstall(", "refresh(force:", "prepareCleanupDryRun("] { XCTAssertFalse(source.contains(token), token) }
        XCTAssertEqual(FeatureLightfieldResultFixture.apps.count, 36)
        XCTAssertEqual(FeatureLightfieldResultFixture.healthSnapshot.disk.smartStatus, .failing)
        XCTAssertTrue(FeatureLightfieldResultFixture.apps.allSatisfy { $0.path.hasPrefix("/Fixture/") })
        let pipeline = try text("Sources/StorageCleanerMac/Debug/MainWindowSnapshotPipeline.swift")
        XCTAssertTrue(pipeline.contains("phase != .result || FeatureLightfield.owns(module)"))
    }

    private func equal(_ lhs: CGPoint, _ rhs: CGPoint, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: 0.5, message, file: file, line: line)
    }
    private func text(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
    // MARK: Round 6 — production result pages, selection and history entry

    func testProductionUninstallRowSelectionNeverOpensPreview() async throws {
        let store = try productionStore()
        store.installedApps = FeatureLightfieldProductionResult.installedApps
        store.hasScannedInstalledApps = true
        let root = AdaptivePageViewport(resetID: .uninstall) { AppUninstallerView(store: store) }
            .environment(\.featureDisablesLayoutAnimations, true).environment(\.featureLightfieldModule, .uninstall)
            .transaction { $0.disablesAnimations = true }
        let size = CGSize(width: 1070, height: 735)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.primary", "lightfield.results.scrollViewport",
            "lightfield.uninstall.row.0", "fixture.viewport"], size: size)
        let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
        let first = try XCTUnwrap(AppUninstallListPresentation.make(apps: store.installedApps.filter(\.canMoveToTrash),
            query: "", filter: .all, sortMode: .recommendation).apps.first)
        // D70's approved uninstall render uses decimal storage units for both
        // the visible row and its complete accessible label.
        let row = first.name + " · " + first.path + " · " + ByteFormat.storageString(first.sizeBytes)
        let primary = L10n.text("卸载所选", "Uninstall Selected")
        try await host.waitForAccessibility(labels: [row, primary], expectedValues: [row: L10n.text("未选择", "Not selected")],
            expectedEnabled: [primary: false], pressLabels: [row], hitTestViewport: viewport)
        XCTAssertTrue(try host.press(label: row))
        try await host.waitForAccessibility(labels: [row, primary], expectedValues: [row: L10n.text("已选择", "Selected")],
            expectedEnabled: [primary: true], hitTestViewport: viewport)
        XCTAssertNil(store.pendingUninstallApp, "Selecting a row must not open the uninstall preview")
        XCTAssertFalse(store.isPreparingUninstall)
        // The primary action opens the preview for the selected application.
        XCTAssertTrue(try host.press(label: primary))
        XCTAssertEqual(store.pendingUninstallApp?.id, first.id)
        let deadline = Date().addingTimeInterval(15)
        while store.isPreparingUninstall, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isPreparingUninstall)
        // Closing the preview keeps the selection, so the action stays usable.
        store.cancelUninstall()
        XCTAssertNil(store.pendingUninstallApp)
        try await host.waitForAccessibility(labels: [row, primary], expectedValues: [row: L10n.text("已选择", "Selected")],
            expectedEnabled: [primary: true], hitTestViewport: viewport)
    }

    func testLongUninstallListLaysOutOnlyVisibleRows() async throws {
        let store = try productionStore()
        store.installedApps = (0..<400).map { index in
            InstalledAppItem(id: "lazy-\(index)", name: "Lazy \(index)", bundleIdentifier: "invalid.example.lazy.\(index)",
                path: "/Applications/Lazy Fixture \(index).app", version: "1.0", build: "1", category: "", appDescription: "",
                sizeBytes: Int64(400 - index) * 1_000_000, source: "fixture", modifiedAt: nil, relatedPaths: [],
                relatedItems: [], status: .installed)
        }
        store.hasScannedInstalledApps = true
        let root = AdaptivePageViewport(resetID: .uninstall) { AppUninstallerView(store: store) }
            .environment(\.featureDisablesLayoutAnimations, true).environment(\.featureLightfieldModule, .uninstall)
            .transaction { $0.disablesAnimations = true }
        let size = CGSize(width: 1070, height: 735)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.uninstall.row.0", "lightfield.listDocument",
            "fixture.viewport"], size: size)
        // The document still has the full height (every row is one row tall)…
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames["lightfield.listDocument"]).height, 400 * FeatureLightfield.rowHeight)
        // …but rows far below the viewport are never instantiated or measured.
        let laidOut = frames.keys.filter { $0.hasPrefix("lightfield.uninstall.row.") }.count
        XCTAssertLessThan(laidOut, 60, "Only rows near the viewport are laid out; got \(laidOut)")
        XCTAssertNil(frames["lightfield.uninstall.row.399"])
        // Rows compute their columns with a Layout, not a per-row GeometryReader.
        let template = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift")
        let row = try XCTUnwrap(template.range(of: "struct FeatureLightfieldResultRow<"))
        let rowEnd = try XCTUnwrap(template.range(of: "struct FeatureLightfieldRowColumns: Layout", range: row.upperBound..<template.endIndex))
        let rowSource = template[row.lowerBound..<rowEnd.lowerBound]
        XCTAssertTrue(rowSource.contains("FeatureLightfieldRowColumns(reservesTrailing: reservesTrailing) {"))
        XCTAssertFalse(rowSource.contains("GeometryReader { proxy in"))
    }

    func testProductionCleanupGroupSelectionSpeaksItsState() async throws {
        let store = try productionStore()
        store.installDebugSmartScanSessionFixture(.results)
        let session = try XCTUnwrap(store.cleanupScanSession)
        let view = CleanupScanResultsView(store: store, filter: .green, session: session)
        let root = AdaptivePageViewport(resetID: .green) { view }
            .environment(\.featureDisablesLayoutAnimations, true).environment(\.featureLightfieldModule, .green)
            .transaction { $0.disablesAnimations = true }
        let size = CGSize(width: 1070, height: 735)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
        defer { host.close() }
        let groups = session.categories.flatMap(\.subcategories).filter { $0.risk == .safe && !$0.selectableCandidateIDs.isEmpty }
        XCTAssertFalse(groups.isEmpty)
        let probes = groups.map { "lightfield.cleanup.group." + $0.id }
        let frames = try await host.frames(required: Set(probes + ["lightfield.results.scrollViewport", "fixture.viewport"]), size: size)
        let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
        let boxes = try probes.map { try XCTUnwrap(frames[$0]) }
        var spoken: [String: String] = [:]
        for group in groups {
            let label = group.title + " · " + view.riskSelectionSummary(risk: group.risk)
            spoken[label] = store.cleanupSelection.groupState(for: group.selectableCandidateIDs, in: session).cleanupAccessibilityValue
        }
        try await host.waitForAccessibility(labels: Array(spoken.keys), expectedValues: spoken,
            hitTestFrames: boxes, hitTestViewport: viewport)
        let all: Set<String> = [L10n.text("未选择", "Not selected"), L10n.text("已选择", "Selected"), L10n.text("部分选择", "Partially selected")]
        XCTAssertTrue(Set(spoken.values).isSubset(of: all))
        let cleanup = try text("Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        let button = try XCTUnwrap(cleanup.range(of: "private func lightfieldSelectionButton("))
        let buttonEnd = try XCTUnwrap(cleanup.range(of: "/// Same scan measurements", range: button.upperBound..<cleanup.endIndex))
        let source = cleanup[button.lowerBound..<buttonEnd.lowerBound]
        XCTAssertTrue(source.contains(".accessibilityValue(state.cleanupAccessibilityValue)"))
        XCTAssertTrue(source.contains("按空格切换此分组的选择状态。"))
    }

    func testProductionResultPagesFillContentRemainClippedAndShowHistory() async throws {
        for module in FeatureLightfield.pilots {
            for window in [CGSize(width: 1280, height: 763), CGSize(width: 1000, height: 700), CGSize(width: 677, height: 390)] {
                let size = CGSize(width: window.width - 210, height: window.height - 28)
                let root = try fixture(module: module, phase: .result).environment(\.featureOperationHistoryAction, {})
                let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
                defer { host.close() }
                let frames = try await host.frames(required: ["lightfield.content", "lightfield.primary",
                    "lightfield.results.scrollViewport", "lightfield.results.fade", "lightfield.status.history",
                    "fixture.viewport"], size: size)
                let context = "\(module)/\(window)"
                let content = try XCTUnwrap(frames["lightfield.content"])
                let primary = try XCTUnwrap(frames["lightfield.primary"])
                let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
                let fade = try XCTUnwrap(frames["lightfield.results.fade"])
                XCTAssertEqual(primary.minY - content.maxY, 16, accuracy: 0.5, context)
                XCTAssertLessThanOrEqual(viewport.maxY, content.maxY + 0.5, context)
                XCTAssertEqual(fade.maxY, viewport.maxY, accuracy: 0.5, context)
                XCTAssertTrue(try XCTUnwrap(frames["lightfield.status"]).insetBy(dx: -0.5, dy: -0.5)
                    .contains(try XCTUnwrap(frames["lightfield.status.history"])), context)
                if module != .healthHub {
                    // Result toolbars start at the list's leading edge, not centred.
                    let toolbar = try XCTUnwrap(frames["lightfield.results.toolbar"], context)
                    XCTAssertEqual(toolbar.minX, content.minX, accuracy: 0.5, context)
                }
                // D77 uses the full native scroll viewport. Partially visible
                // edge rows are clipped by it; the footer is outside the clip.
                XCTAssertGreaterThan(frames.keys.filter { $0.hasPrefix("lightfield.value.") || $0.hasPrefix("lightfield.note.") }.count, 0, context)
                XCTAssertLessThanOrEqual(viewport.maxY, primary.minY - 16 + 0.5, context)
            }
        }
    }

    func testOperationHistoryEntryOnD67PagesOpensTheSharedSheet() async throws {
        final class Counter { var value = 0 }
        let counter = Counter()
        let page = FeatureLightfieldPage(module: .uninstall, phase: .result, title: "Fixture", status: "Status",
            safety: "Safety", actionTitle: "Act", action: {}) { Text("Body") }
            .environment(\.featureOperationHistoryAction, { counter.value += 1 })
            .environment(\.featureDisablesLayoutAnimations, true)
        let size = CGSize(width: 1070, height: 735)
        let host = CalibrationAppKitLayoutHost(root: page, size: size, dark: false)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.status", "lightfield.status.history",
            "lightfield.status.divider", "lightfield.status.safety", "fixture.viewport"], size: size)
        let history = try XCTUnwrap(frames["lightfield.status.history"])
        XCTAssertLessThan(history.maxX, try XCTUnwrap(frames["lightfield.status.divider"]).minX)
        XCTAssertEqual(history.minX, try XCTUnwrap(frames["lightfield.status"]).minX, accuracy: 0.5)
        let label = L10n.text("操作记录", "Operation History")
        try await host.waitForAccessibility(labels: [label], pressLabels: [label])
        XCTAssertTrue(try host.press(label: label))
        XCTAssertEqual(counter.value, 1)
        let content = try text("Sources/StorageCleanerMac/Views/ContentView.swift")
        XCTAssertTrue(content.contains(".environment(\\.featureOperationHistoryAction, { isShowingOperationHistory = true })"))
        XCTAssertTrue(content.contains(".toolbar(FeatureLightfield.owns(activePresentationFilter) ? .hidden : .visible, for: .windowToolbar)"))
    }

    /// Round 6 P2 items that are presentation-only; the screenshots in
    /// visual-r6 are their visual evidence.
    func testRoundSixPresentationContracts() throws {
        let content = try text("Sources/StorageCleanerMac/Views/ContentView.swift")
        XCTAssertTrue(content.contains("ideal: sidebarMode == .full ? FeatureLightfield.sidebarWidth : sidebarMode.idealWidth"))
        XCTAssertFalse(content.contains("FeatureLightfield.owns(activePresentationFilter) && sidebarMode == .full"),
            "The full sidebar is 210 pt on every page")
        let sidebar = try text("Sources/StorageCleanerMac/Views/SidebarView.swift")
        XCTAssertTrue(sidebar.contains("SidebarChrome(isRail: isRail, usesLightfield: FeatureLightfield.owns(selection))"))
        XCTAssertTrue(sidebar.contains("if followsPureBlack { surfaces.sidebar }"))
        let cleanup = try text("Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        let start = try XCTUnwrap(cleanup.range(of: "private var lightfieldResults: some View"))
        let end = try XCTUnwrap(cleanup.range(of: "private static let topAnchorID", range: start.upperBound..<cleanup.endIndex))
        let pilot = String(cleanup[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(pilot.contains("只永久删除扫描时废纸篓里已有的 \\(entryCount) 项"))
        XCTAssertTrue(pilot.contains("Text(L10n.text(\"无法读取废纸篓\", \"Trash Cannot Be Read\"))"))
        XCTAssertTrue(pilot.contains("_ = CleanupService.openFullDiskAccessSettings()"))
        XCTAssertTrue(pilot.contains(".padding(.leading, FeatureLightfield.childRowIndent)"))
        XCTAssertEqual(FeatureLightfield.childRowIndent, 36)
        XCTAssertTrue(cleanup.contains("value: CleanupMeasurementPresentation.value(candidate), note: lightfieldNote)"))
        XCTAssertTrue(cleanup.contains("candidate.isOwnerRunning ? ownerStatusLine?.text : nil"))
        let template = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift")
        XCTAssertTrue(template.contains("Text(note).font(.system(size: 12.5)).lineLimit(1).fixedSize()\n                        .foregroundStyle(palette.warningColor)"))
        XCTAssertTrue(template.contains(".init(color: .black, location: min(1, FeatureLightfield.haloEdgeFade / max(1, canvas.size.width)))"))
        XCTAssertEqual(FeatureLightfield.haloEdgeFade, 96)
        let templates = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureTemplates.swift")
        XCTAssertTrue(templates.contains("status: state.title + (RuntimeWorkflowState.measuredFraction(fraction).map { \" · \\(Int($0 * 100))%\" } ?? \"\"),"))
        XCTAssertFalse(templates.contains("status: state.title + \" · \" + title,"), "The stage is not repeated in the status line")
    }

    private func productionStore() throws -> ScanStore {
        let defaults = TestPreferenceDomain.make(for: self)
        return try ScanStore.makeForTests(for: self, restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) }, scanHistoryDefaults: defaults,
            menuBarMemoryStatusProvider: { XCTFail("No live provider in D67 fixture"); return MiniWindowDemoData.memorySnapshot },
            menuBarMemoryProcessProvider: { XCTFail("No live provider in D67 fixture"); return MiniWindowDemoData.memorySnapshot },
            cleanupScanOperation: { _, _ in XCTFail("No cleanup operation in D67 fixture"); throw CancellationError() },
            cleanupPreferences: defaults, cleanReportLoader: { [] }, interruptedOperationReconciler: { [] })
    }

    private func fixture(module: ReviewFilter, phase: FeaturePresentationDemo.Phase) throws -> some View {
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try ScanStore.makeForTests(for: self, restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) }, scanHistoryDefaults: defaults,
            menuBarMemoryStatusProvider: { XCTFail("No live provider in D67 fixture"); return MiniWindowDemoData.memorySnapshot },
            menuBarMemoryProcessProvider: { XCTFail("No live provider in D67 fixture"); return MiniWindowDemoData.memorySnapshot },
            cleanupScanOperation: { _, _ in XCTFail("No cleanup operation in D67 fixture"); throw CancellationError() },
            cleanupPreferences: defaults, cleanReportLoader: { [] }, interruptedOperationReconciler: { [] })
        let session = FeaturePresentationDemo(); session.phase = phase
        let health = ComputerHealthStore(probe: LightfieldInertProbe(), batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
        return AdaptivePageViewport(resetID: module) {
            FeaturePresentationDemoView(session: session, store: store, module: module, healthStore: health,
                networkStore: NetworkSpeedTestStore(), browserStore: BrowserPrivacyStore())
        }.environment(\.featureDisablesLayoutAnimations, true)
            .environment(\.featureLightfieldModule, module)
            .transaction { $0.disablesAnimations = true }
    }
}
private struct LightfieldInertProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot { XCTFail("No hardware reads in D67 fixture"); throw CancellationError() }
}

/// Merge D74 resident caching with D72's visible, session-bound telemetry.
/// Every request below is synthetic; no helper or benchmark workload is run.
@MainActor
final class HelperPowerMetricsMergeTests: XCTestCase {
    private final class Box<T> { var value: T; init(_ value: T) { self.value = value } }
    private var sample: PowermetricsSample {
        .init(cpuMilliwatts: 5_000, gpuMilliwatts: 2_000, aneMilliwatts: 0,
              clusters: [.init(name: "P0", kind: .performance, megahertz: 3_200)],
              gpuMegahertz: 800, durationSeconds: 1)
    }
    private func cadence(lowPower: Bool = false, suspended: Bool = false) -> MenuBarSamplingCadence {
        .resolve(visible: false, lowPower: lowPower, suspended: suspended, selectedInterval: 1)
    }

    func testActualBridgeLeaseRestoresResidentCadenceAndLowPowerWins() async {
        let time = Box(100.0), calls = Box(0), nanoseconds = Box(UInt64(100_000_000_000))
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1; nanoseconds.value += 1; return .sample(self.sample)
        }, now: { time.value }, automaticSampling: false, monotonicNanoseconds: { nanoseconds.value })
        monitor.useResidentScheduler(); monitor.setResidentCadence(cadence())
        let bridge = MSeriesV11TelemetryBridge(monitor: monitor, now: { nanoseconds.value })
        let otherPage = UUID()
        bridge.setVisible(true); bridge.beginSession()
        await monitor.sampleIfDue()
        time.value = 102; nanoseconds.value = 102_000_000_000
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 2); XCTAssertEqual(bridge.readings.count, 2)
        monitor.updateConsumer(otherPage, visible: true)
        bridge.setVisible(false) // the observer remains, but its own lease ends
        time.value = 104; await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 2, "another page cannot prolong v11's two-second rate")
        time.value = 107; await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 3); XCTAssertEqual(bridge.readings.count, 2)
        monitor.updateConsumer(otherPage, visible: false)
        time.value = 166; await monitor.sampleIfDue(); XCTAssertEqual(calls.value, 3)
        time.value = 167; await monitor.sampleIfDue(); XCTAssertEqual(calls.value, 4)
        bridge.setVisible(true)
        monitor.setResidentCadence(cadence(lowPower: true))
        time.value = 169; await monitor.sampleIfDue(); XCTAssertEqual(calls.value, 4)
        time.value = 347; await monitor.sampleIfDue(); XCTAssertEqual(calls.value, 5)
        monitor.setResidentSuspended(true)
        time.value = 1_000; await monitor.sampleIfDue(); XCTAssertEqual(calls.value, 5)
        bridge.finish()
        XCTAssertFalse(monitor.hasDemand)
    }

    func testPassiveObserverDoesNotAccelerateAnotherConsumer() async {
        let time = Box(100.0), calls = Box(0)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1; return .sample(self.sample)
        }, now: { time.value }, automaticSampling: false)
        monitor.useResidentScheduler(); monitor.setResidentCadence(cadence())
        let observer = monitor.observeReadings { _ in }
        let page = UUID(); monitor.updateConsumer(page, visible: true)
        await monitor.sampleIfDue()
        time.value = 102; await monitor.sampleIfDue(); XCTAssertEqual(calls.value, 1)
        time.value = 105; await monitor.sampleIfDue(); XCTAssertEqual(calls.value, 2)
        monitor.updateConsumer(page, visible: false); monitor.removeReadingObserver(observer)
    }

    func testResidentFailureRetainsOriginalDateButNeverPublishesFreshEvidence() async {
        let time = Box(100.0), date = Box(Date(timeIntervalSinceReferenceDate: 100)), calls = Box(0)
        let deliveries = Box(0)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1
            return calls.value == 1 ? .sample(self.sample) : .failure(.timedOut)
        }, now: { time.value }, wallClock: { date.value }, automaticSampling: false)
        monitor.useResidentScheduler(); monitor.setResidentCadence(cadence())
        let observer = monitor.observeReadings { _ in deliveries.value += 1 }
        await monitor.sampleIfDue(); let kept = monitor.state
        XCTAssertNotNil(monitor.latestReading)
        time.value = 160; date.value = .init(timeIntervalSinceReferenceDate: 160)
        await monitor.sampleIfDue()
        XCTAssertEqual(monitor.state, kept); XCTAssertEqual(monitor.lastFailure, .timedOut)
        XCTAssertNil(monitor.latestReading); XCTAssertEqual(deliveries.value, 1)
        XCTAssertEqual(monitor.history.count, 1)
        XCTAssertEqual(monitor.history.first?.date, .init(timeIntervalSinceReferenceDate: 100))
        monitor.removeReadingObserver(observer)
    }

    func testSleepAndReopeningDoNotOverlapOrPublishAnOldPhysicalFlight() async {
        let time = Box(100.0), calls = Box(0)
        let gate = Box<CheckedContinuation<PowermetricsResult, Never>?>(nil)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1
            if calls.value == 1 { return await withCheckedContinuation { gate.value = $0 } }
            return .sample(self.sample)
        }, now: { time.value }, automaticSampling: false)
        monitor.useResidentScheduler(); monitor.setResidentCadence(cadence())
        let bridge = MSeriesV11TelemetryBridge(monitor: monitor)
        bridge.setVisible(true); bridge.beginSession()
        let first = Task { await monitor.sampleIfDue() }
        for _ in 0..<10_000 { if gate.value != nil { break }; await Task.yield() }
        guard let continuation = gate.value else { bridge.finish(); return XCTFail("synthetic request did not enter gate") }
        monitor.setResidentSuspended(true)
        bridge.finish(); bridge.beginSession()
        monitor.setResidentSuspended(false)
        time.value = 104; await monitor.sampleIfDue(); XCTAssertEqual(calls.value, 1)
        continuation.resume(returning: .sample(sample)); await first.value
        XCTAssertNil(monitor.latestReading); XCTAssertTrue(bridge.readings.isEmpty)
        XCTAssertTrue(monitor.history.isEmpty)
        await monitor.sampleIfDue(); XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(bridge.readings.count, 1)
        bridge.finish()
    }
}

@MainActor
final class LightfieldMergeContractTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
    func testWholeBaselineFitIncludesTheChineseUnitAndLongStatus() {
        for diameter in [CGFloat(48), 76, 100, 160] {
            let geometry = LightfieldRingGeometry(diameter: diameter)
            for status in [true, false] {
                let value = "999999999.99", unit = "固定负载/秒", label = "暂定芯片性能分"
                let typography = LightfieldRingTypography(geometry: geometry, value: value,
                    unit: unit, label: label, status: status)
                let number = (value as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: typography.valueSize, weight: .bold)]).width
                let suffix = (unit as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: typography.unitSize, weight: .medium)]).width
                let caption = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: typography.labelSize, weight: status ? .semibold : .regular)]).width
                XCTAssertLessThanOrEqual(number + suffix + 2, geometry.textBounds.width)
                XCTAssertLessThanOrEqual(caption, geometry.textBounds.width)
            }
        }
    }
    func testIntegratedChartInteractionAndV11AxesExistTogether() throws {
        let chart = try source("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldCharts.swift")
        for expression in ["var secondaryAxis: LightfieldTrendAxis?", "var pointLabels: [String]",
            "Text(LightfieldAxisLabel.display(text))", "var color: Color?", "var linkedID: String?",
            "var emphasizedIDs: Set<String>?", "layoutCache.placements(values: values, size: proxy.size)",
            "selectedID == nil || selectedID == item.id", "Button { onSelect(item.id) }"] {
            XCTAssertTrue(chart.contains(expression), expression)
        }
        let capture = try source("Sources/StorageCleanerMac/Debug/MainWindowSnapshotPipeline.swift")
        for field in ["benchmarkV11Variant", "benchmarkV11Section", "benchmarkV11Stage", "analysisView"] {
            XCTAssertTrue(capture.contains("\"" + field + "\":"), field)
        }
    }
    func testIntegratedNumericSitesRemainExactAndCannotBorrowEachOthersMarkers() throws {
        let paths = MSeriesV11ScaleContract.allowed.keys.filter { $0.contains("FilesLightfield/") || $0.hasSuffix("LargeFilesView.swift") || $0.hasSuffix("FeatureLightfieldFileComponents.swift") }
        XCTAssertEqual(paths.count, 5)
        for path in paths {
            let original = try source(path)
            XCTAssertTrue(MSeriesV11ScaleContract.violations(path: path, source: original).isEmpty, path)
            for counterexample in [
                original.replacingOccurrences(of: ".minimumScaleFactor(0.5)", with: ".minimumScaleFactor(0.01)"),
                original.replacingOccurrences(of: ".lineLimit(1).minimumScaleFactor", with: ".lineLimit(2).minimumScaleFactor"),
                original + "\nText(\"ordinary caption\").lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok",
                original.replacingOccurrences(of: ".minimumScaleFactor(0.5)", with: ".minimumScaleFactor(0.5).overlay { Text(\"ordinary caption\").lineLimit(1).minimumScaleFactor(0.01) }")
            ] { XCTAssertFalse(MSeriesV11ScaleContract.violations(path: path, source: counterexample).isEmpty, path) }
            XCTAssertFalse(MSeriesV11ScaleContract.violations(path: "Other/" + path, source: original).isEmpty)
        }
    }
}
#endif
