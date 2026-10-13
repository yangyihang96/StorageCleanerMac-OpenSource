#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Native frames and AX from production views with synthetic, in-memory values.
/// No benchmark Store, provider, workload, helper, or history writer is created.
@MainActor
final class MSeriesV11NativeLayoutTests: XCTestCase {
    private let windows: [CGSize] = [
        .init(width: 820, height: 560), .init(width: 1000, height: 700),
        .init(width: 1280, height: 763), .init(width: 1680, height: 1050),
        .init(width: 2400, height: 1350), .init(width: 677, height: 390),
        .init(width: 1280, height: 390)
    ]
    private let variants = ["standard", "provisional", "nohelper", "unavailable"]
    private let skeleton: Set<String> = [
        "lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status", "fixture.viewport"
    ]

    func testProductionThreeStatesKeepSkeletonAcrossSevenWindowsBothSchemesAndLanguages() async throws {
        try await matrix { window, size, dark, language in
            var reference: [String: CGRect]?
            for phase in FeatureLightfieldPhase.allCases {
                let capture = MSeriesV11NativeCapture()
                let host = self.host(page: self.page(phase: phase), capture: capture, size: size, dark: dark)
                defer { host.close() }
                let frames = try await host.frames(required: self.skeleton, size: size)
                let context = "\(phase)/\(window)/\(dark)/\(language)"
                try self.assertSkeleton(frames, window: window, phase: phase, context: context)
                if phase != .result, let reference {
                    for id in ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status"] {
                        let actual = try XCTUnwrap(frames[id]), expected = try XCTUnwrap(reference[id])
                        self.equal(actual.origin, expected.origin, context + "/" + id)
                        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, context + "/" + id)
                        if id != "lightfield.content" {
                            XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, context + "/" + id)
                        }
                    }
                } else if phase != .result { reference = frames }
                try await host.waitForAccessibility(labels: [self.actionTitle(phase)], pressLabels: [self.actionTitle(phase)])
            }
        }
    }

    func testCurrentRestrictedHistoryHostsAllThreeGrayMetricsAndReasons() async throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            for dark in [false, true] {
                let record = try MSeriesV11HistoryScorePresentationTests.record(restrictedIDs: ["chip", "system", "efficiency"])
                let id = record.session.id.uuidString
                let capture = MSeriesV11NativeCapture(), size = CGSize(width: 600, height: 350)
                let view = PerformanceBenchmarkV11HistoryList(history: [record], current: record, onOpen: { _ in
                    XCTFail("read-only history layout must not open a record")
                }).frame(width: 400, alignment: .leading)
                let host = self.host(page: AnyView(view), capture: capture, size: size, dark: dark)
                defer { host.close() }
                let names = ["chip", "system", "efficiency"]
                var required = Set<String>()
                let scorePrefix = "performance.history.scores." + id
                for name in names {
                    required.insert(scorePrefix + ".value." + name)
                    required.insert(scorePrefix + ".column." + name)
                    required.insert("performance.history.restricted." + name + "." + id)
                }
                let frames = try await host.frames(required: required, size: size)
                for name in names {
                    let value = try XCTUnwrap(frames["performance.history.scores." + id + ".value." + name])
                    let column = try XCTUnwrap(frames["performance.history.scores." + id + ".column." + name])
                    let reason = try XCTUnwrap(frames["performance.history.restricted." + name + "." + id])
                    XCTAssertGreaterThan(value.width, 0)
                    XCTAssertGreaterThan(value.height, 0)
                    self.horizontallyContained(value, in: column, "restricted history/" + name)
                    XCTAssertGreaterThan(reason.width, 0)
                    XCTAssertGreaterThan(reason.height, 0)
                    self.contained(reason, in: CGRect(origin: .zero, size: size), "history reason/" + name)
                }
            }
        }
    }

    func testRatioGridStaysInsideContentAtOnePointRoundingBoundary() async throws {
        let window = CGSize(width: 1000, height: 700)
        let size = CGSize(width: window.width - FeatureLightfield.sidebarWidth,
            height: window.height - FeatureLightfield.titlebarHeight)
        for variant in variants {
            let capture = MSeriesV11NativeCapture()
            let host = self.host(page: self.resultPage(MSeriesV11PageFixture.result(variant: variant)), capture: capture, size: size, dark: false)
            defer { host.close() }
            let ratioIDs = ["cpuSingle", "cpuMulti", "gpuPeak", "gpuSustained"].map { "performance.ratio." + $0 }
            let ids = Set(ratioIDs + ["lightfield.content"])
            let frames = try await host.frames(required: ids, size: size)
            let content = try XCTUnwrap(frames["lightfield.content"])
            for id in ratioIDs { self.horizontallyContained(try XCTUnwrap(frames[id]), in: content, variant + "/" + id) }
        }
    }

    func testAllReferenceVariantsAndHugeNumbersKeepResultSummaryAndRatioColumnsContained() async throws {
        try await matrix { window, size, dark, language in
            for variant in self.variants {
                for huge in [false, true] {
                    let result = try self.result(variant: variant, huge: huge)
                    let envelope = try XCTUnwrap(result.mSeriesV11)
                    let capture = MSeriesV11NativeCapture()
                    let host = self.host(page: self.resultPage(result), capture: capture, size: size, dark: dark)
                    defer { host.close() }
                    let ratioIDs = ["cpuSingle", "cpuMulti", "gpuPeak", "gpuSustained"]
                    let ids = self.skeleton.union([
                        "performance.summary.container", "performance.summary", "performance.summary.primary", "performance.summary.caption",
                        "performance.summary.secondary.system", "performance.summary.secondary.efficiency",
                        "lightfield.result.summary", "performance.result.scroll"
                    ])
                    let frames = try await host.frames(required: ids, size: size)
                    let context = "\(variant)/huge=\(huge)/\(window)/\(dark)/\(language)"
                    try self.assertSkeleton(frames, window: window, phase: .result, context: context)
                    let content = try XCTUnwrap(frames["lightfield.content"])
                    // D77: compact scores fit the <=72 pt header; at narrow
                    // widths the two secondary scores move into the details.
                    let summary = try XCTUnwrap(frames["performance.summary.container"])
                    let header = try XCTUnwrap(frames["lightfield.result.summary"])
                    self.contained(summary, in: header, context + "/compact summary")
                    XCTAssertLessThanOrEqual(header.maxY, 72.5, context)
                    XCTAssertFalse(header.intersects(content), context + "/header/list separation")
                    let primary = try XCTUnwrap(frames["performance.summary.primary"])
                    let system = try XCTUnwrap(frames["performance.summary.secondary.system"])
                    let efficiency = try XCTUnwrap(frames["performance.summary.secondary.efficiency"])
                    for (name, rect) in [("primary", primary), ("system", system), ("efficiency", efficiency)] {
                        self.contained(rect, in: name != "primary" && content.width < 600 ? content : summary, context + "/" + name)
                    }
                    XCTAssertLessThanOrEqual(system.maxX, efficiency.minX + 0.5, context + "/secondary overlap")
                    XCTAssertFalse(primary.intersects(system), context + "/primary/secondary separation")
                    self.scoreFits("chip", result: envelope, frame: primary, valueSize: 22, prefixSize: 13,
                        weight: .semibold, context: context + "/chip")
                    for id in ["system", "efficiency"] {
                        let values = try await host.frames(required: ids.union(["performance.summary.secondary.value." + id]), size: size)
                        let valueFrame = try XCTUnwrap(values["performance.summary.secondary.value." + id])
                        let column = try XCTUnwrap(values["performance.summary.secondary." + id])
                        self.contained(valueFrame, in: column, context + "/" + id + "/value column")
                        self.scoreFits(id, result: envelope, frame: valueFrame, valueSize: 22, prefixSize: 13,
                            weight: .semibold, context: context + "/" + id)
                    }
                    var nativeText = capture.accessibilityText(at: [summary, system, efficiency]) + "\n"
                    let captionBefore = try XCTUnwrap(frames["performance.summary.caption"])
                    try capture.reveal(captionBefore, in: try XCTUnwrap(frames["performance.result.scroll"]))
                    let captionFrames = try await host.frames(required: ids, size: size)
                    let caption = try XCTUnwrap(captionFrames["performance.summary.caption"])
                    self.contained(caption, in: try XCTUnwrap(captionFrames["performance.result.scroll"]), context + "/reachable reference caption")
                    nativeText += capture.accessibilityText(at: [caption]) + "\n"
                    self.equal(try XCTUnwrap(captionFrames["lightfield.primary"]).origin,
                        try XCTUnwrap(frames["lightfield.primary"]).origin, context + "/pinned action")
                    for id in ratioIDs {
                        let required = ids.union(["performance.ratio." + id])
                        let before = try await host.frames(required: required, size: size)
                        try capture.reveal(try XCTUnwrap(before["performance.ratio." + id]),
                            in: try XCTUnwrap(before["performance.result.scroll"]))
                        let values = try await host.frames(required: required, size: size)
                        let frame = try XCTUnwrap(values["performance.ratio." + id])
                        self.horizontallyContained(frame, in: content, context + "/ratio/" + id)
                        self.contained(frame, in: try XCTUnwrap(values["performance.result.scroll"]),
                            context + "/ratio/" + id + "/reachable")
                        let text = MSeriesV11PagePresentation.ratio(id, result: envelope)
                            .map { MSeriesV11PagePresentation.number($0, digits: 2) + "×" }
                            ?? MSeriesV11PagePresentation.calibration
                        self.textFits(text, frame: frame, font: .monospacedSystemFont(ofSize: 17, weight: .semibold),
                            minimumScale: 0.5, context: context + "/ratio/" + id)
                    }
                    try await host.waitForAccessibility(labels: [self.actionTitle(.result)], pressLabels: [self.actionTitle(.result)])
                    XCTAssertTrue(nativeText.contains(MSeriesV11PagePresentation.referenceCaption(envelope)), context + "/reference caption")
                    if variant == "provisional" {
                        for id in ["chip", "system", "efficiency"] {
                            let text = MSeriesV11PagePresentation.score(id, result: envelope)
                            XCTAssertTrue(text.hasPrefix(L10n.text("暂定 ", "Provisional ")), context + "/" + id)
                            XCTAssertTrue(nativeText.contains(text), context + "/native " + id)
                        }
                    } else if variant == "unavailable" {
                        XCTAssertTrue(nativeText.contains(MSeriesV11PagePresentation.calibration), context)
                    }
                }
            }
        }
    }

    func testRunningValuesStayInTheirNativeColumnsAndCancelIsAnInertCallback() async throws {
        try await matrix { window, size, dark, language in
            let capture = MSeriesV11NativeCapture()
            let actions = MSeriesV11NativeActions()
            let host = self.host(page: self.runningPage(onCancel: { actions.cancelCount += 1 }),
                capture: capture, size: size, dark: dark)
            defer { host.close() }
            let fields = ["power", "frequency", "temperature"]
            let ids = self.skeleton.union(["performance.running.percent", "performance.running.metrics"])
                .union(fields.flatMap { ["performance.running.metrics.column." + $0,
                    "performance.running.metrics.value." + $0, "performance.running.metrics.label." + $0] })
            let frames = try await host.frames(required: ids, size: size)
            let context = "running/\(window)/\(dark)/\(language)"
            let content = try XCTUnwrap(frames["lightfield.content"])
            self.horizontallyContained(try XCTUnwrap(frames["performance.running.percent"]), in: content, context)
            let metrics = try XCTUnwrap(frames["performance.running.metrics"])
            self.horizontallyContained(metrics, in: content, context)
            for field in fields {
                let column = try XCTUnwrap(frames["performance.running.metrics.column." + field])
                self.contained(column, in: metrics, context + "/" + field)
                for kind in ["label", "value"] {
                    self.contained(try XCTUnwrap(frames["performance.running.metrics." + kind + "." + field]),
                        in: column, context + "/" + field + "/" + kind)
                }
            }
            let cancel = self.actionTitle(.running)
            try await host.waitForAccessibility(labels: [cancel], pressLabels: [cancel])
            XCTAssertTrue(try host.press(label: cancel))
            XCTAssertEqual(actions.cancelCount, 1, "Only the fixture callback may run")
        }
    }

    func testNoHelperSettingsHasNativeAXPressAndItsVisibleFrameStaysReachable() async throws {
        try await matrix { window, size, dark, language in
            let result = MSeriesV11PageFixture.result(variant: "nohelper")
            let capture = MSeriesV11NativeCapture()
            let host = self.host(page: self.resultPage(result), capture: capture, size: size, dark: dark)
            defer { host.close() }
            let buttonIDs = ["performance.helper.settings.summary", "performance.helper.settings.curve"]
            let ids = self.skeleton.union(["performance.result.scroll", "performance.summary.container",
                "performance.summary.secondary.efficiency", "performance.helper.required.summary"]).union(buttonIDs)
            let frames = try await host.frames(required: ids, size: size)
            let label = L10n.text("去设置 · 系统助手", "Settings · System Helper")
            let content = try XCTUnwrap(frames["lightfield.content"])
            let helperBefore = try XCTUnwrap(frames["performance.helper.required.summary"])
            try capture.reveal(helperBefore, in: try XCTUnwrap(frames["performance.result.scroll"]))
            let helperFrames = try await host.frames(required: ids, size: size)
            let helper = try XCTUnwrap(helperFrames["performance.helper.required.summary"])
            let helperText = try await capture.regionText(containing: MSeriesV11PagePresentation.helperRequired,
                frame: helper, viewport: content)
            XCTAssertTrue(helperText.contains(MSeriesV11PagePresentation.helperRequired))
            for id in buttonIDs {
                let before = try await host.frames(required: ids, size: size)
                try capture.reveal(try XCTUnwrap(before[id]), in: try XCTUnwrap(before["performance.result.scroll"]))
                let after = try await host.frames(required: ids, size: size)
                let buttonFrame = try XCTUnwrap(after[id])
                let viewport = try XCTUnwrap(after["performance.result.scroll"])
                let context = "settings/\(id)/\(window)/\(dark)/\(language)"
                self.contained(buttonFrame, in: viewport, context + "/visible probe")
                // Both actions have the same label. Resolve the native action
                // at this exact probe, never the first matching sibling.
                let button = try await capture.settingsButton(label: label, frame: buttonFrame,
                    viewport: viewport, context: context)
                XCTAssertTrue(button.object.responds(to: NSSelectorFromString("accessibilityPerformPress")))
                self.contained(button.frame, in: viewport, context + "/native action")
                self.equal(button.frame.origin, buttonFrame.origin, context + "/native origin")
                XCTAssertEqual(button.frame.width, buttonFrame.width, accuracy: 0.5, context)
                XCTAssertEqual(button.frame.height, buttonFrame.height, accuracy: 0.5, context)
            }
            // Deliberately do not press: the production action requests real Settings.
        }
    }

    func testAllEighteenRawValuesCanBeScrolledIntoTheRealViewportIncludingHugeValues() async throws {
        try await matrix { window, size, dark, language in
            for huge in [false, true] {
                let result = try self.result(variant: "standard", huge: huge)
                XCTAssertEqual(try XCTUnwrap(result.mSeries).metrics.map(\.id), MSeriesProtocol.coreIDs)
                let capture = MSeriesV11NativeCapture()
                let host = self.host(page: self.resultPage(result, initialSection: 2), capture: capture, size: size, dark: dark)
                defer { host.close() }
                let initial = try await host.frames(required: self.skeleton.union(["performance.result.scroll"]), size: size)
                let viewport = try XCTUnwrap(initial["performance.result.scroll"])
                let primary = try XCTUnwrap(initial["lightfield.primary"])
                for id in MSeriesProtocol.coreIDs {
                    let required: Set<String> = ["performance.raw." + id, "performance.raw.value." + id,
                        "performance.result.scroll", "lightfield.primary", "fixture.viewport"]
                    let before = try await host.frames(required: required, size: size)
                    // A combined AX row owns its title, value and unit. Reveal
                    // that whole real row, not only its second-line value.
                    try capture.reveal(try XCTUnwrap(before["performance.raw." + id]), in: viewport)
                    let after = try await host.frames(required: required, size: size)
                    let actualViewport = try XCTUnwrap(after["performance.result.scroll"])
                    let actual = try XCTUnwrap(after["performance.raw.value." + id])
                    let row = try XCTUnwrap(after["performance.raw." + id])
                    let context = "raw/\(id)/huge=\(huge)/\(window)/\(dark)/\(language)"
                    self.contained(actual, in: actualViewport, context + "/reachable value")
                    self.contained(actual, in: row, context + "/value column")
                    self.horizontallyContained(row, in: actualViewport, context + "/row")
                    XCTAssertEqual(actualViewport.height, viewport.height, accuracy: 0.5, context)
                    self.equal(try XCTUnwrap(after["lightfield.primary"]).origin, primary.origin, context + "/pinned action")
                    let metric = try XCTUnwrap(result.mSeries?.metrics.first { $0.id == id })
                    let text = MSeriesV11PagePresentation.number(metric.statistics?.median, digits: 2)
                    self.textFits(text, frame: actual,
                        font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), minimumScale: 0.5, context: context)
                    let unit = MSeriesV11PagePresentation.unit(metric.unit)
                    let readback = try await capture.rawRowText(title: MSeriesV11PagePresentation.itemTitle(id),
                        value: text, unit: unit, row: row, valueFrame: actual, viewport: actualViewport, context: context)
                    XCTAssertTrue(readback.text.contains(text), context + "/native raw value; " + readback.diagnostic)
                    XCTAssertTrue(readback.text.contains(unit), context + "/native unit; " + readback.diagnostic)
                }
            }
        }
    }

    func testEnlargedRealCurveInputsKeepAxisAndThreadLabelsInsideNativeTextBounds() async throws {
        let result = try enlargedCurveResult()
        let envelope = try XCTUnwrap(result.mSeriesV11)
        let points = envelope.efficiencyPoints.filter { $0.id.hasPrefix("power.cpu.") && MSeriesV11PagePresentation.measuredEfficiencyPoint($0, in: envelope) }
            .sorted { ($0.meanPowerW ?? 0) < ($1.meanPowerW ?? 0) }
        XCTAssertEqual(points.count, 3, "the native page must show actual rebuilt efficiency points")
        XCTAssertGreaterThan(try XCTUnwrap(points.last?.throughput?.statistics?.median), 1e12)
        try await matrix { window, size, dark, language in
            let capture = MSeriesV11NativeCapture()
            let host = self.host(page: self.resultPage(result), capture: capture, size: size, dark: dark)
            defer { host.close() }
            let scrollID = "performance.result.scroll"
            let cpuIDs = ["top", "middle", "bottom"].map { "performance.efficiency.chart.axis." + $0 }
            let sustainedIDs = ["top", "middle", "bottom"].map { "performance.sustained.chart.axis." + $0 }
            let pointIDs = points.indices.map { "performance.efficiency.chart.pointLabel." + String($0) }
            let legendIDs = [L10n.text("吞吐", "Throughput"), L10n.text("温度", "Temperature")].map { "lightfield.trend.legend." + $0 }
            let required = Set(cpuIDs + sustainedIDs + pointIDs + legendIDs + [scrollID, "performance.efficiency.chart.plot", "performance.sustained.chart.plot"])
            let initial = try await host.frames(required: required, size: size)
            let powerMaximum = max(1, (points.compactMap { $0.throughput?.statistics?.median }.max() ?? 0) * 1.1)
            let sustainedMaximum = max(1, (envelope.sustainedCPU?.windows.compactMap(\.wallThroughput).max() ?? 0) * 1.1)
            let texts = [powerMaximum, powerMaximum / 2, 0, sustainedMaximum, sustainedMaximum / 2, 0]
                .map { LightfieldAxisLabel.display(MSeriesV11PagePresentation.number($0, digits: 0)) }
            for (id, text) in zip(cpuIDs + sustainedIDs, texts) {
                let before = try await host.frames(required: required, size: size)
                try capture.reveal(try XCTUnwrap(before[id]), in: try XCTUnwrap(before[scrollID]))
                let frames = try await host.frames(required: required, size: size)
                let frame = try XCTUnwrap(frames[id])
                self.contained(frame, in: try XCTUnwrap(frames[scrollID]), "curve axis/\(window)/\(language)/" + id)
                self.textFits(text, frame: frame, font: .monospacedSystemFont(ofSize: 11, weight: .regular), minimumScale: 0.75, context: id)
                XCTAssertEqual(frame.width, 36, accuracy: 0.5)
            }
            for (index, id) in pointIDs.enumerated() {
                let label = try XCTUnwrap(initial[id]), plot = try XCTUnwrap(initial["performance.efficiency.chart.plot"])
                self.contained(label, in: plot, "thread point/" + id)
                self.textFits(String(try XCTUnwrap(points[index].resolvedWorkers)) + L10n.text("线程", " threads"),
                    frame: label, font: .systemFont(ofSize: 11), minimumScale: 1, context: id)
            }
            for id in legendIDs { XCTAssertGreaterThan(try XCTUnwrap(initial[id]).width, 0) }
        }
    }

    private func enlargedCurveResult() throws -> BenchmarkV7Result {
        let source = MSeriesV11PageFixture.result()
        var envelope = try XCTUnwrap(source.mSeriesV11)
        envelope.workloadBatches = try envelope.workloadBatches.map { batch in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
            object["workUnits"] = batch.workUnits * 1e12
            return try JSONDecoder().decode(MSeriesV11Batch.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let batches = envelope.workloadBatches, telemetry = envelope.telemetry, hash = envelope.extensionContractHash
        envelope.efficiencyPoints = try envelope.efficiencyPoints.map { point in
            let first = try XCTUnwrap(point.windows.first), last = try XCTUnwrap(point.windows.last)
            let duration = Int(MSeriesV11Windows.seconds(first.startMonotonicNs, last.endMonotonicNs).rounded())
            let matched = batches.filter { $0.stageID == point.id }
            let windows = MSeriesV11Windows.windows(id: point.id, start: first.startMonotonicNs, durationSeconds: duration,
                count: point.windows.count, finishedAt: last.endMonotonicNs, batches: matched, telemetry: telemetry, gpu: point.id.contains("gpu"))
            return MSeriesV11Windows.efficiencyPoint(id: point.id, workers: try XCTUnwrap(point.resolvedWorkers),
                coreType: try XCTUnwrap(point.coreType), windows: windows, batches: matched, telemetry: telemetry, extensionHash: hash)
        }
        if let old = envelope.sustainedCPU, let first = old.windows.first, let last = old.windows.last {
            let matched = batches.filter { $0.stageID == old.id }
            let observations = old.windows.map { MSeriesV11Observation(atMonotonicNs: $0.startMonotonicNs,
                cpuTemperatureC: $0.temperatureC ?? 55, gpuTemperatureC: nil, environment: MSeriesV11TestFixtures.nominal) }
            let windows = MSeriesV11Windows.windows(id: old.id, start: first.startMonotonicNs, durationSeconds: 90,
                count: 18, finishedAt: last.endMonotonicNs, batches: matched, telemetry: telemetry, observations: observations, gpu: false)
            envelope.sustainedCPU = MSeriesV11Windows.sustained(id: old.id, duration: 90, windows: windows,
                batches: matched, extensionHash: hash, gpu: false)
        }
        // Display-only scaled inputs, rebuilt with matching work/power windows.
        // Never persisted, scored as a reference, or passed to a real kernel.
        return .init(recordID: source.recordID, mSeries: source.mSeries, mSeriesV11: envelope, session: source.session,
            preflight: source.preflight, versions: source.versions, metrics: [], coreScore: nil,
            completedAt: source.completedAt, failure: nil)
    }

    func testLegacyV9AndV10RoundTripAndOriginalResultSubviewsRemainDisplayable() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let fixtures = try ["legacy-v9", "legacy-v10"].map { variant -> (String, BenchmarkV7Result) in
            let original = MSeriesV11PageFixture.result(variant: variant)
            let decoded = try decoder.decode(BenchmarkV7Result.self, from: encoder.encode(original))
            XCTAssertEqual(decoded, original)
            XCTAssertNil(decoded.mSeriesV11, "Opening legacy history must not fabricate a v11 envelope")
            return (variant, decoded)
        }
        try await matrix { window, size, dark, language in
            for (variant, result) in fixtures {
                let view: AnyView
                let title: String
                if let raw = result.mSeries {
                    XCTAssertEqual(raw.metrics.count, 18)
                    view = AnyView(MSeriesRawResultView(result: raw))
                    title = L10n.text("Core 测量完整 · 原始结果", "Complete Core · raw results")
                } else {
                    let profile = try XCTUnwrap(BenchmarkV7PerformanceProfile(coreScore: result.coreScore))
                    view = AnyView(BenchmarkV7PerformanceSummaryView(profile: profile,
                        accent: FeatureLightfieldPalette.accent(.performance)))
                    title = self.legacyStrengthAXLabel(profile)
                }
                let capture = MSeriesV11NativeCapture()
                let legacy = AnyView(ScrollView(.vertical) {
                    view.frame(maxWidth: .infinity, alignment: .leading).layoutProbe("legacy.result")
                }.layoutProbe("legacy.scroll"))
                let host = self.host(page: legacy, capture: capture, size: size, dark: dark)
                defer { host.close() }
                let frames = try await host.frames(required: ["legacy.result", "legacy.scroll", "fixture.viewport"], size: size)
                let viewport = try XCTUnwrap(frames["fixture.viewport"])
                self.contained(try XCTUnwrap(frames["legacy.scroll"]), in: viewport, variant + "/" + String(describing: window))
                self.horizontallyContained(try XCTUnwrap(frames["legacy.result"]), in: viewport,
                    "\(variant)/\(window)/\(dark)/\(language)")
                if result.mSeries != nil {
                    let heading = try await capture.legacyTitle(title,
                        viewFrame: try XCTUnwrap(frames["legacy.result"]), viewport: viewport)
                    self.contained(heading.frame, in: viewport, "legacy-v10/native title frame")
                    XCTAssertEqual(heading.value, title)
                } else {
                    try await host.waitForAccessibility(labels: [title], expectedValues: [title: title], hitTestViewport: viewport)
                    XCTAssertEqual(try host.accessibilityValue(label: title), title)
                }
            }
        }
        // BenchmarkV7DashboardView requires a leaderboard Store. This is the
        // authorized pure-subview fallback, not full Dashboard route acceptance.
    }

    private func matrix(_ body: @MainActor (CGSize, CGSize, Bool, AppLanguage) async throws -> Void) async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let volatile = TestVolatilePreferences()
        defer { volatile.restore() }
        for language in [AppLanguage.zhHans, .english] {
            defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            volatile.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            XCTAssertEqual(L10n.appLanguage, language)
            XCTAssertEqual(defaults.string(forKey: L10n.languageDefaultsKey), language.rawValue)
            for dark in [false, true] {
                for window in windows {
                    let size = CGSize(width: window.width - FeatureLightfield.sidebarWidth,
                        height: window.height - FeatureLightfield.titlebarHeight)
                    try await body(window, size, dark, language)
                }
            }
        }
    }

    private func host(page: AnyView, capture: MSeriesV11NativeCapture, size: CGSize, dark: Bool) -> CalibrationAppKitLayoutHost {
        let root = AdaptivePageViewport(resetID: .performance) { page }
            .environment(\.featureDisablesLayoutAnimations, true)
            .environment(\.moduleTheme, ReviewFilter.performance.moduleTheme)
            .background(MSeriesV11NativeAnchor(capture: capture))
        return CalibrationAppKitLayoutHost(root: root, size: size, dark: dark)
    }

    private func page(phase: FeatureLightfieldPhase) -> AnyView {
        switch phase {
        case .landing: return AnyView(PerformanceBenchmarkV11DemoPage(phase: .landing))
        case .running: return AnyView(PerformanceBenchmarkV11DemoPage(phase: .running))
        case .result: return AnyView(PerformanceBenchmarkV11DemoPage(phase: .result))
        }
    }

    private func runningPage(onCancel: @escaping () -> Void) -> AnyView {
        let state = MSeriesV11PageFixture.runState
        return AnyView(PerformanceBenchmarkV11RunningPage(run: .init(state: state,
            weightedFraction: 68.0 / 460.0, elapsedSeconds: 68),
            telemetry: MSeriesV11PageFixture.telemetry,
            systemTelemetry: PerformanceBenchmarkV11DemoPage.systemTelemetry, onCancel: onCancel))
    }

    private func resultPage(_ result: BenchmarkV7Result, initialSection: Int = 0) -> AnyView {
        AnyView(PerformanceBenchmarkV11ResultPage(result: result, history: [result],
            catalog: MSeriesV11PageFixture.catalog, canStart: true, onStart: {}, onOpenHistory: { _ in },
            initialSection: initialSection))
    }

    private func result(variant: String, huge: Bool) throws -> BenchmarkV7Result {
        let source = MSeriesV11PageFixture.result(variant: variant)
        guard huge else { return source }
        var envelope = try XCTUnwrap(source.mSeriesV11)
        if let scores = envelope.scores {
            envelope.scores = .init(componentScores: scores.componentScores.mapValues { _ in 987_654_321_098_765 },
                labels: scores.labels, referenceIdentity: scores.referenceIdentity, scoreStatus: scores.scoreStatus)
        }
        let core = try XCTUnwrap(source.mSeries)
        let measurements = try core.metrics.map { metric -> MSeriesMeasurement in
            let samples = (0..<3).map { _ in BenchmarkV7RawSample(value: 987_654_321_098.75,
                elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 1) }
            return .init(id: metric.id, unit: metric.unit, availability: metric.availability,
                reason: metric.reason, samples: samples, statistics: try BenchmarkStatistics.summarize(samples.map(\.value)),
                repetitions: metric.repetitions, workers: metric.workers)
        }
        let hugeCore = MSeriesResult(sessionID: core.sessionID, schema: core.schema, plan: core.plan,
            workload: core.workload, fixture: core.fixture, implementation: core.implementation,
            statisticsVersion: core.statisticsVersion, scoringVersion: core.scoringVersion,
            referenceVersion: core.referenceVersion, contractHash: core.contractHash, hardware: core.hardware,
            coreEnvironment: core.coreEnvironment, metrics: measurements, extensions: core.extensions,
            cancelled: core.cancelled, globalFailure: core.globalFailure, writtenBytes: core.writtenBytes,
            startedAt: core.startedAt, completedAt: core.completedAt)
        // Deliberately display-only: do not reseal, persist, or activate this
        // extreme cached-score fixture as a genuine measured/reference result.
        return .init(recordID: source.recordID, mSeries: hugeCore, mSeriesV11: envelope,
            session: source.session, preflight: source.preflight, versions: source.versions,
            metrics: source.metrics, coreScore: source.coreScore, runtimeWarnings: ["nativeLayoutExtremeValuesOnly"],
            completionStatus: source.completionStatus, completedAt: source.completedAt, failure: source.failure)
    }

    private func actionTitle(_ phase: FeatureLightfieldPhase) -> String {
        switch phase {
        case .landing: L10n.text("开始测试", "Start test")
        case .running: L10n.text("取消", "Cancel")
        case .result: L10n.text("重新测试", "Test again")
        }
    }

    /// The original insight uses children: .combine. Assert its complete
    /// native value, in the same semantic order as the original view's data.
    private func legacyStrengthAXLabel(_ profile: BenchmarkV7PerformanceProfile) -> String {
        let category: String = switch profile.strongest.category {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: L10n.text("内存", "Memory")
        case .storage: L10n.text("存储", "Storage")
        case .display: L10n.text("显示体验", "Display experience")
        case .sustained: L10n.text("持续检查", "Sustained check")
        }
        let difference = profile.strongest.ratio - 1
        let reference: String
        if difference >= 0.05 {
            let percent = difference.formatted(.percent.precision(.fractionLength(0)))
            reference = L10n.text("高于 V7 基准 " + percent, percent + " above V7 reference")
        } else if difference <= -0.05 {
            let percent = (-difference).formatted(.percent.precision(.fractionLength(0)))
            reference = L10n.text("低于 V7 基准 " + percent, percent + " below V7 reference")
        } else { reference = L10n.text("接近 V7 基准", "Near V7 reference") }
        return [L10n.text("相对强项", "Relative strength"), category, reference].joined(separator: ", ")
    }

    private func assertSkeleton(_ frames: [String: CGRect], window: CGSize,
                                phase: FeatureLightfieldPhase, context: String) throws {
        let viewport = try XCTUnwrap(frames["fixture.viewport"])
        let title = try XCTUnwrap(frames["lightfield.title"])
        let content = try XCTUnwrap(frames["lightfield.content"])
        let primary = try XCTUnwrap(frames["lightfield.primary"])
        let status = try XCTUnwrap(frames["lightfield.status"])
        for (name, rect) in [("title", title), ("content", content), ("primary", primary), ("status", status)] {
            contained(rect, in: viewport, context + "/" + name)
        }
        if phase == .result {
            try assertCompactResultSkeleton(frames, window: window)
        } else {
            XCTAssertEqual(primary.height, 52, accuracy: 0.5, context)
            XCTAssertEqual(status.height, 64, accuracy: 0.5, context)
            XCTAssertEqual(primary.minY - content.maxY, 24, accuracy: 0.5, context)
            XCTAssertEqual(status.minY - primary.maxY, 24, accuracy: 0.5, context)
            XCTAssertEqual(primary.minY, viewport.maxY - 140, accuracy: 0.5, context)
            XCTAssertEqual(status.minY, viewport.maxY - 64, accuracy: 0.5, context)
            if window == CGSize(width: 1280, height: 763) {
                equal(title.origin, .init(x: 96, y: 92), context)
                equal(content.origin, .init(x: 96, y: 176), context)
                equal(primary.origin, .init(x: 96, y: 595), context)
                equal(status.origin, .init(x: 52, y: 671), context)
                XCTAssertEqual(primary.width, 520, accuracy: 0.5, context)
                XCTAssertEqual(content.width, phase == .result ? 878 : 520, accuracy: 0.5, context)
            }
        }
    }

    private func contained(_ child: CGRect, in parent: CGRect, _ context: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(child.width.isFinite && child.height.isFinite && child.width > 0 && child.height > 0,
            context + "/finite nonempty", file: file, line: line)
        XCTAssertTrue(parent.insetBy(dx: -0.5, dy: -0.5).contains(child),
            "\(context): \(child) outside \(parent)", file: file, line: line)
    }

    private func horizontallyContained(_ child: CGRect, in parent: CGRect, _ context: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(child.minX, parent.minX - 0.5, context, file: file, line: line)
        XCTAssertLessThanOrEqual(child.maxX, parent.maxX + 0.5, context, file: file, line: line)
    }

    private func equal(_ actual: CGPoint, _ expected: CGPoint, _ context: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.5, context, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.5, context, file: file, line: line)
    }

    private func textFits(_ text: String, frame: CGRect, font: NSFont, minimumScale: CGFloat, context: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        let glyphs = (text as NSString).size(withAttributes: [.font: font])
        XCTAssertGreaterThanOrEqual(frame.width + 0.5, glyphs.width * minimumScale,
            context + "/complete glyphs at the minimum allowed scale", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height + 0.5, (font.ascender - font.descender) * minimumScale,
            context + "/glyph height", file: file, line: line)
    }

    private func scoreFits(_ id: String, result: MSeriesV11Result, frame: CGRect,
                           valueSize: CGFloat, prefixSize: CGFloat, weight: NSFont.Weight, context: String) {
        let parts = MSeriesV11PagePresentation.scoreParts(id, result: result)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: weight)
        let prefixFont = NSFont.systemFont(ofSize: prefixSize)
        let valueWidth = (parts.value as NSString).size(withAttributes: [.font: valueFont]).width
        let prefixWidth = (parts.prefix as NSString).size(withAttributes: [.font: prefixFont]).width
        XCTAssertGreaterThanOrEqual(frame.width + 0.5, (valueWidth + prefixWidth) * 0.5,
            context + "/complete prefix and value at the production minimum scale")
        XCTAssertGreaterThanOrEqual(frame.height + 0.5, (valueFont.ascender - valueFont.descender) * 0.5,
            context + "/glyph height")
    }
}

@MainActor
private final class MSeriesV11NativeActions {
    var cancelCount = 0
}

/// Only captures the test host's own native view. It does not search other
/// windows, expose new controls, replace AX nodes, or alter production layout.
@MainActor
private final class MSeriesV11NativeCapture {
    weak var anchor: NSView?

    struct RawReadback {
        let text: String
        let diagnostic: String
    }

    struct NativeButton {
        let object: NSObject
        let frame: CGRect
    }

    struct LegacyTitle {
        let frame: CGRect
        let value: String
    }

    /// Discovery only: sample the measured original view's leading 512 pt of
    /// its top 80 pt every 4 pt. Wide windows keep the native title at the left;
    /// spreading hit points over the full 2,190 pt view misses that text.
    /// Neither the title view nor its accessibility text is replaced.
    func legacyTitle(_ expected: String, viewFrame: CGRect, viewport: CGRect) async throws -> LegacyTitle {
        let root = try XCTUnwrap(anchor?.window?.contentView)
        let window = try XCTUnwrap(root.window)
        let top = CGRect(x: viewFrame.minX, y: viewFrame.minY, width: min(512, viewFrame.width),
            height: min(80, viewFrame.height)).intersection(viewport)
        var diagnostic = "No native title node"
        for _ in 0..<100 {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await Task.yield()
            var samples = [String]()
            for offset in stride(from: CGFloat.zero, to: top.height, by: CGFloat(4)) {
                let band = CGRect(x: top.minX, y: top.minY + offset,
                    width: top.width, height: min(4, top.height - offset))
                let nodes = rawNodes(row: band, valueFrame: band, viewport: viewport, root: root, window: window)
                for node in nodes {
                    guard let frame = node.frame, frame.intersects(band),
                          viewFrame.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          nativeString(objectValue(node.object, "accessibilityRole")) == NSAccessibility.Role.staticText.rawValue,
                          let value = nativeString(objectValue(node.object, "accessibilityValue")) else { continue }
                    if value == expected { return .init(frame: frame, value: value) }
                    if samples.count < 20 { samples.append("frame=\(frame), value=\(value.debugDescription)") }
                }
            }
            diagnostic = samples.joined(separator: "; ")
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "MSeriesV11NativeLayoutTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Legacy v10 exact native title missing in measured top band \(top); expected=\(expected.debugDescription); \(diagnostic)"])
    }

    private struct RawNode {
        let object: NSObject
        let frame: CGRect?
        let text: String
        let source: String
    }

    func reveal(_ value: CGRect, in viewport: CGRect) throws {
        let root = try XCTUnwrap(anchor?.window?.contentView, "Fixture native view not attached")
        let scroll = try XCTUnwrap(scrollViews(in: root).first { candidate in
            let rect = candidate.convert(candidate.bounds, to: root)
            return abs(rect.minX - viewport.minX) <= 0.5 && abs(rect.width - viewport.width) <= 0.5
        }, "Production result ScrollView not found at its measured viewport")
        let document = try XCTUnwrap(scroll.documentView)
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let target = min(maximum, max(0, scroll.contentView.bounds.minY + value.minY - viewport.minY - 4))
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        root.layoutSubtreeIfNeeded()
    }

    /// The geometry readiness gate does not wait for SwiftUI's independent
    /// native AX publication. Reacquire after each main-actor turn, using the
    /// existing host's 100 x 5 ms AX budget, and accept only the target row.
    func rawRowText(title: String, value: String, unit: String, row: CGRect, valueFrame: CGRect,
                    viewport: CGRect, context: String) async throws -> RawReadback {
        let root = try XCTUnwrap(anchor?.window?.contentView, "Fixture native view not attached")
        let window = try XCTUnwrap(root.window)
        var last = RawReadback(text: "", diagnostic: "Native AX not queried")
        for attempt in 0..<100 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            let nodes = rawNodes(row: row, valueFrame: valueFrame, viewport: viewport, root: root, window: window)
            // Do not collect unrelated values from the whole hosting tree:
            // huge-value fixtures deliberately have identical numbers in all
            // 18 rows. Title and native frame identify the real combined row.
            let target = nodes.first { node in
                guard let frame = node.frame else { return false }
                return row.insetBy(dx: -0.5, dy: -0.5).contains(frame)
                    && frame.intersects(valueFrame) && node.text.contains(title)
                    && node.text.contains(value) && node.text.contains(unit)
            }
            let partial = nodes.first { node in
                guard let frame = node.frame else { return false }
                return row.insetBy(dx: -0.5, dy: -0.5).contains(frame)
                    && frame.intersects(valueFrame) && node.text.contains(title)
            }
            let native = target ?? partial
            let scroll = scrollViews(in: root).first { view in
                let frame = view.convert(view.bounds, to: root)
                return abs(frame.minX - viewport.minX) <= 0.5 && abs(frame.width - viewport.width) <= 0.5
            }
            let diagnostic = "attempt=\(attempt + 1); root=\(type(of: root)), flipped=\(root.isFlipped), bounds=\(root.bounds); "
                + "row=\(row), valueFrame=\(valueFrame), viewport=\(viewport); clip=\(String(describing: scroll?.contentView.bounds)); "
                + "native=\(String(describing: native?.frame)); nodes=" + nodes.prefix(40).map { node in
                    "[\(node.source), \(type(of: node.object)), frame=\(String(describing: node.frame)), text=\(node.text.debugDescription)]"
                }.joined(separator: "; ")
            last = .init(text: native?.text ?? "", diagnostic: diagnostic)
            if target != nil { return last }
            try await Task.sleep(for: .milliseconds(5))
        }
        FileHandle.standardError.write(Data("V11 native raw AX failure: \(context); expectedTitle=\(title.debugDescription), "
            .appending("expectedValue=\(value.debugDescription), expectedUnit=\(unit.debugDescription); \(last.diagnostic)\n").utf8))
        return last
    }

    func settingsButton(label: String, frame: CGRect, viewport: CGRect, context: String) async throws -> NativeButton {
        let root = try XCTUnwrap(anchor?.window?.contentView)
        let window = try XCTUnwrap(root.window)
        var diagnostic = "No native nodes"
        for _ in 0..<100 {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await Task.yield()
            let nodes = rawNodes(row: frame, valueFrame: frame, viewport: viewport, root: root, window: window)
            for node in nodes {
                guard let actual = node.frame,
                      abs(actual.minX - frame.minX) <= 0.5, abs(actual.minY - frame.minY) <= 0.5,
                      abs(actual.width - frame.width) <= 0.5, abs(actual.height - frame.height) <= 0.5,
                      nativeString(objectValue(node.object, "accessibilityRole")) == NSAccessibility.Role.button.rawValue,
                      node.object.responds(to: NSSelectorFromString("accessibilityPerformPress")),
                      ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].contains(where: {
                          nativeString(objectValue(node.object, $0)) == label
                      }) else { continue }
                return .init(object: node.object, frame: actual)
            }
            diagnostic = nodes.prefix(40).map {
                "\($0.source): \(type(of: $0.object)), frame=\(String(describing: $0.frame)), text=\($0.text.debugDescription)"
            }.joined(separator: "; ")
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "MSeriesV11NativeLayoutTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(context): native Settings AXButton not found at \(frame); \(diagnostic)"])
    }

    func regionText(containing expected: String, frame: CGRect, viewport: CGRect) async throws -> String {
        let root = try XCTUnwrap(anchor?.window?.contentView)
        let window = try XCTUnwrap(root.window)
        var last = ""
        for _ in 0..<100 {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await Task.yield()
            last = rawNodes(row: frame, valueFrame: frame, viewport: viewport, root: root, window: window)
                .filter { $0.frame?.intersects(frame.intersection(viewport)) == true }
                .map(\.text).joined(separator: "\n")
            if last.contains(expected) { return last }
            try await Task.sleep(for: .milliseconds(5))
        }
        return last
    }

    private func rawNodes(row: CGRect, valueFrame: CGRect, viewport: CGRect,
                          root: NSView, window: NSWindow) -> [RawNode] {
        let visible = row.intersection(viewport).intersection(root.bounds)
        guard !visible.isNull, !visible.isEmpty else { return [] }
        let scroll = scrollViews(in: root).first { view in
            let frame = view.convert(view.bounds, to: root)
            return abs(frame.minX - viewport.minX) <= 0.5 && abs(frame.width - viewport.width) <= 0.5
        }
        // These are this fixture's actual AppKit views. The document root can
        // expose native virtual descendants omitted by the hosting root.
        var hitRoots = [root]
        if let scroll { hitRoots.append(scroll.contentView); if let document = scroll.documentView { hitRoots.append(document) } }
        var pending = [(NSObject, String)]()
        for frame in [visible, valueFrame.intersection(visible)] where !frame.isNull && !frame.isEmpty {
            for y in 0..<3 {
                for x in 0..<5 {
                    let point = CGPoint(x: frame.minX + (CGFloat(x) + 0.5) * frame.width / 5,
                        y: frame.minY + (CGFloat(y) + 0.5) * frame.height / 3)
                    let windowPoint = root.convert(point, to: nil)
                    let screenPoint = window.convertToScreen(CGRect(origin: windowPoint, size: .zero)).origin
                    for view in hitRoots {
                        if let node = view.accessibilityHitTest(screenPoint) as? NSObject {
                            pending.append((node, "hit \(type(of: view)) @\(point)"))
                        }
                    }
                }
            }
        }
        // Navigation order is a public AX relationship that the original
        // capture omitted. Never manufacture a row label or numeric value.
        pending += hitRoots.map { ($0 as NSObject, "fixture \(type(of: $0))") }
        var seen = Set<ObjectIdentifier>()
        var nodes = [RawNode]()
        var index = 0
        while index < pending.count, seen.count < 2_000 {
            let (object, source) = pending[index]; index += 1
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            // accessibilityFrame returns NSRect, not an Objective-C object;
            // NSObject.perform would use the wrong return ABI. Match the
            // existing host's public KVC boxing of this struct property.
            let nativeFrame: CGRect?
            if object.responds(to: NSSelectorFromString("accessibilityFrame")),
               let rect = object.value(forKey: "accessibilityFrame") as? NSValue {
                nativeFrame = root.convert(window.convertFromScreen(rect.rectValue), from: nil)
            } else { nativeFrame = nil }
            let text = ["accessibilityTitle", "accessibilityLabel", "accessibilityValue", "accessibilityValueDescription"]
                .compactMap { nativeString(objectValue(object, $0)) }.joined(separator: "\n")
            if nativeFrame?.intersects(visible) == true || source.hasPrefix("hit ") {
                nodes.append(.init(object: object, frame: nativeFrame, text: text, source: source))
            }
            for name in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
                for case let child as NSObject in objectValue(object, name) as? [Any] ?? [] {
                    pending.append((child, name + " of " + String(describing: type(of: object))))
                }
            }
            if let parent = objectValue(object, "accessibilityParent") as? NSObject,
               !(parent is NSApplication) { pending.append((parent, "parent of " + String(describing: type(of: object)))) }
        }
        return nodes
    }

    private func objectValue(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func nativeString(_ value: AnyObject?) -> String? {
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    func accessibilityText(at frames: [CGRect]) -> String {
        guard let root = anchor?.window?.contentView else { return "" }
        var visited = Set<ObjectIdentifier>()
        var text = [String]()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            for name in ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() {
                    if let string = value as? String { text.append(string) }
                    else if let string = value as? NSAttributedString { text.append(string.string) }
                }
            }
            for name in ["accessibilityChildren", "accessibilityContents"] {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector),
                      let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { continue }
                for child in children { if let child = child as? NSObject { visit(child) } }
            }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        if let window = root.window {
            for frame in frames {
                for y in [frame.minY + 1, frame.midY, frame.maxY - 1] {
                    for x in [frame.minX + 1, frame.midX, frame.maxX - 1] {
                        let point = CGPoint(x: x, y: y)
                        guard root.bounds.contains(point) else { continue }
                        let windowPoint = root.convert(point, to: nil)
                        let screenPoint = window.convertToScreen(CGRect(origin: windowPoint, size: .zero)).origin
                        var current = root.accessibilityHitTest(screenPoint) as? NSObject
                        var parents = Set<ObjectIdentifier>()
                        for _ in 0..<8 {
                            guard let node = current, parents.insert(ObjectIdentifier(node)).inserted else { break }
                            visit(node)
                            let selector = NSSelectorFromString("accessibilityParent")
                            current = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? NSObject : nil
                        }
                    }
                }
            }
        }
        return text.joined(separator: "\n")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }
}

private struct MSeriesV11NativeAnchor: NSViewRepresentable {
    let capture: MSeriesV11NativeCapture
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        capture.anchor = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
