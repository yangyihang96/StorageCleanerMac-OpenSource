#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FeatureLightfieldComponentTests: XCTestCase {
    private let windows: [CGSize] = [.init(width: 820, height: 560), .init(width: 1000, height: 700),
        .init(width: 1280, height: 763), .init(width: 1680, height: 1050), .init(width: 2400, height: 1350),
        .init(width: 677, height: 390), .init(width: 1280, height: 390)]

    func testOptionRowDimensionsSelectionPressAndFixedStaticText() async throws {
        let callbacks = LightfieldComponentCallbacks()
        let size = CGSize(width: 520, height: 240)
        let host = lightfieldHost(root: LightfieldOptionTestFixture(callbacks: callbacks), size: size, dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["option", "option.icon", "fixed", "fixture.viewport"], size: size)
        XCTAssertEqual(try XCTUnwrap(frames["option"]).height, 56, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frames["option.icon"]).size, .init(width: 28, height: 28))
        try await host.waitForAccessibility(labels: ["选择范围", "固定项目 · 6 项"],
            expectedValues: ["选择范围": L10n.text("已选", "Selected")], pressLabels: ["选择范围"])
        XCTAssertTrue(try host.press(label: "选择范围"))
        try await host.waitForAccessibility(labels: ["选择范围"], expectedValues: ["选择范围": L10n.text("未选", "Not selected")])
        XCTAssertFalse(callbacks.selected)
        XCTAssertNil(host.element(label: "固定项目 · 6 项", requiresPress: true), "A fixed row has no AX press action")
    }

    func testAppIconThreeSizesAndUnifiedDaemonFallback() async throws {
        for size in LightfieldAppIcon.Size.allCases {
            let viewport = CGSize(width: 100, height: 100)
            let host = lightfieldHost(root: LightfieldAppIcon(size: size, accessibilityName: "系统进程")
                .layoutProbe("icon"), size: viewport, dark: false)
            defer { host.close() }
            let frames = try await host.frames(required: ["icon", "fixture.viewport"], size: viewport)
            XCTAssertEqual(try XCTUnwrap(frames["icon"]).width, CGFloat(size.rawValue), accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(frames["icon"]).height, CGFloat(size.rawValue), accuracy: 0.5)
            try await host.waitForAccessibility(labels: ["系统进程"])
        }
        let source = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift")
        XCTAssertTrue(source.contains("CachedAppIconView(path: path ?? \"\""))
        XCTAssertTrue(source.contains("Image(systemName: \"gearshape.fill\")"))
    }

    func testStatusGlyphUsesExistingRestrictionSymbolsAndAXDescriptions() async throws {
        for status in MetadataPillStatus.allCases {
            let size = CGSize(width: 100, height: 100)
            let host = lightfieldHost(root: LightfieldStatusGlyph(status: status).layoutProbe("glyph"), size: size, dark: true)
            defer { host.close() }
            let frames = try await host.frames(required: ["glyph", "fixture.viewport"], size: size)
            XCTAssertEqual(try XCTUnwrap(frames["glyph"]).size, .init(width: 20, height: 20))
            try await host.waitForAccessibility(labels: [status.lightfieldDescription])
            XCTAssertEqual(status.lightfieldSymbol, status.systemImage ?? "checkmark.circle.fill")
            if status != .none { XCTAssertEqual(status.lightfieldDescription, status.accessibilityDescription) }
        }
        XCTAssertEqual(MetadataPillStatus.normal, .none)
        XCTAssertEqual(MetadataPillStatus.systemOnly, .systemSettingsOnly)
    }

    func testRingActualTextAndLongCopyStayInsideInscribedSquareAcrossSevenWindows() async throws {
        for dark in [true, false] {
            for window in windows {
                let size = CGSize(width: window.width - 210, height: window.height - 28)
                let diameter = min(132, max(48, (size.width - 80) / 3))
                for value in ["61", "升高", "12345678901234567890.123456789"] {
                    let host = lightfieldHost(root: LightfieldRing(diameter: diameter, progress: 0.61,
                        color: FeatureLightfieldPalette.accent(.memory), value: value, unit: "百分比单位", label: "非常长的压力与占用标签")
                        .environment(\.featureDisablesLayoutAnimations, true), size: size, dark: dark)
                    defer { host.close() }
                    let required: Set<String> = ["lightfield.ring", "lightfield.ring.text", "lightfield.ring.value", "lightfield.ring.unit", "lightfield.ring.label", "fixture.viewport"]
                    let frames = try await host.frames(required: required, size: size)
                    let ring = try XCTUnwrap(frames["lightfield.ring"])
                    let center = try XCTUnwrap(frames["lightfield.ring.text"])
                    let geometry = LightfieldRingGeometry(diameter: diameter)
                    XCTAssertEqual(ring.width, diameter, accuracy: 0.5)
                    XCTAssertEqual(center.width, geometry.textBounds.width, accuracy: 0.5)
                    XCTAssertEqual(center.midX, ring.midX, accuracy: 0.5)
                    XCTAssertEqual(center.midY, ring.midY, accuracy: 0.5)
                    for suffix in ["value", "unit", "label"] {
                        let actualText = try XCTUnwrap(frames["lightfield.ring." + suffix])
                        XCTAssertTrue(center.insetBy(dx: -0.5, dy: -0.5).contains(actualText), "\(window)/\(value)/\(suffix): \(actualText) outside \(center)")
                    }
                    for corner in [CGPoint(x: center.minX, y: center.minY), .init(x: center.maxX, y: center.maxY)] {
                        XCTAssertLessThanOrEqual(hypot(corner.x - ring.midX, corner.y - ring.midY), diameter / 2 - geometry.stroke + 0.5)
                    }
                }
            }
        }
    }

    func testMetricEqualColumnsAndLongPathsNeverOverflowSevenWindows() async throws {
        let metrics = (0..<6).map { LightfieldMetric(id: String($0), label: "非常长的计数标签 \($0)", value: "123456789012345.678", unit: "GB") }
        for window in windows {
            let size = CGSize(width: window.width - 210, height: 200)
            let host = lightfieldHost(root: VStack {
                LightfieldMetricGroup(metrics: metrics)
                LightfieldPathText(path: "/Applications/" + String(repeating: "Long Application Path/", count: 30))
                    .layoutProbe("path").frame(width: size.width / 3).layoutProbe("path.column")
            }, size: size, dark: false)
            defer { host.close() }
            let ids = ["lightfield.metrics", "path", "path.column", "fixture.viewport"] + metrics.flatMap {
                ["lightfield.metrics.column." + $0.id, "lightfield.metrics.value." + $0.id, "lightfield.metrics.label." + $0.id]
            }
            let frames = try await host.frames(required: Set(ids), size: size)
            let width = try XCTUnwrap(frames["lightfield.metrics.column.0"]).width
            let group = try XCTUnwrap(frames["lightfield.metrics"])
            for metric in metrics {
                let column = try XCTUnwrap(frames["lightfield.metrics.column." + metric.id])
                XCTAssertEqual(column.width, width, accuracy: 0.5)
                XCTAssertTrue(group.insetBy(dx: -0.5, dy: -0.5).contains(column), "Column must remain in the group")
                for field in ["label", "value"] {
                    XCTAssertTrue(column.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames["lightfield.metrics." + field + "." + metric.id])))
                }
            }
            XCTAssertTrue(try XCTUnwrap(frames["path.column"]).insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames["path"])))
        }
    }

    func testDataBarTwoHeightsAndUnknownAXValue() async throws {
        let size = CGSize(width: 520, height: 200)
        let host = lightfieldHost(root: VStack(spacing: 20) {
            LightfieldDataBar(progress: 0.62, module: .memory).layoutProbe("ratio")
            LightfieldDataBar(progress: 0.42, module: .performance, style: .progress(segments: 18)).layoutProbe("progress")
            LightfieldDataBar(progress: nil, module: .memory, accessibilityLabel: "未知进度").layoutProbe("unknown")
        }.environment(\.featureDisablesLayoutAnimations, true), size: size, dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["ratio", "progress", "unknown", "fixture.viewport"], size: size)
        XCTAssertEqual(try XCTUnwrap(frames["ratio"]).height, 2, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frames["progress"]).height, 6, accuracy: 0.5)
        try await host.waitForAccessibility(labels: ["未知进度"], expectedValues: ["未知进度": L10n.text("未提供", "Unavailable")])
    }

    func testExpandableWholeRowAXPressAnd36PointChildIndent() async throws {
        let size = CGSize(width: 520, height: 240)
        let host = lightfieldHost(root: LightfieldExpansionTestFixture(), size: size, dark: true)
        defer { host.close() }
        try await host.waitForAccessibility(labels: ["展开行"], expectedValues: ["展开行": L10n.text("已折叠", "Collapsed")], pressLabels: ["展开行"])
        XCTAssertTrue(try host.press(label: "展开行"))
        try await host.waitForAccessibility(labels: ["展开行", "子行"], expectedValues: ["展开行": L10n.text("已展开", "Expanded")])
        let frames = try await host.frames(required: ["expandable", "child", "fixture.viewport"], size: size)
        XCTAssertEqual(try XCTUnwrap(frames["child"]).minX - XCTUnwrap(frames["expandable"]).minX, 36, accuracy: 0.5)
        XCTAssertTrue(try host.press(label: "展开行"))
        try await host.waitForAccessibility(labels: ["展开行"], expectedValues: ["展开行": L10n.text("已折叠", "Collapsed")])
    }

    func testTextSegmentsAXPressChangesSelectedItem() async throws {
        let size = CGSize(width: 520, height: 100)
        let host = lightfieldHost(root: LightfieldSegmentsTestFixture(), size: size, dark: false)
        defer { host.close() }
        try await host.waitForAccessibility(labels: ["全部", "后台运行"], expectedValues: ["全部": L10n.text("已选", "Selected")], pressLabels: ["后台运行"])
        XCTAssertTrue(try host.press(label: "后台运行"))
        try await host.waitForAccessibility(labels: ["全部", "后台运行"], expectedValues: ["全部": L10n.text("未选", "Not selected"), "后台运行": L10n.text("已选", "Selected")])
    }

    func testBubbleNativePressInvokesDrillDownWithTheItemIdentity() async throws {
        let callbacks = LightfieldComponentCallbacks()
        let size = CGSize(width: 500, height: 300)
        let host = lightfieldHost(root: LightfieldBubbleChart(items: LightfieldComponentGallery.chartItems,
            onHighlight: { callbacks.highlighted = $0 }, onDrillDown: { callbacks.drilled = $0 })
            .environment(\.featureDisablesLayoutAnimations, true), size: size, dark: true)
        defer { host.close() }
        let label = "媒体 · 20 GB"
        try await host.waitForAccessibility(labels: [label], pressLabels: [label])
        XCTAssertTrue(try host.press(label: label))
        XCTAssertEqual(callbacks.drilled, "media")
    }

    /// Review P2-3: bubbles too small to target are not AX elements.
    func testTinyBubblesStayOutOfAccessibility() async throws {
        let size = CGSize(width: 90, height: 60)
        let items = LightfieldComponentGallery.chartItems
        let placements = LightfieldBubbleLayout.placements(values: items.map { ($0.id, $0.value) }, size: size)
        let hidden = placements.filter { $0.radius * 2 < LightfieldBubbleLayout.minimumAccessibleDiameter }.map(\.id)
        let shown = placements.filter { $0.radius * 2 >= LightfieldBubbleLayout.minimumAccessibleDiameter }.map(\.id)
        XCTAssertFalse(hidden.isEmpty, "Fixture must produce a sub-20 pt bubble")
        XCTAssertFalse(shown.isEmpty)
        let host = lightfieldHost(root: LightfieldBubbleChart(items: items).frame(width: size.width, height: size.height), size: size, dark: true)
        defer { host.close() }
        let label = { (id: String) in items.first { $0.id == id }.map { $0.label + " · " + $0.formattedValue } ?? id }
        try await host.waitForAccessibility(labels: shown.map(label))
        for id in hidden { XCTAssertNil(host.element(label: label(id)), id) }
    }

    func testTrendNativeHistoryAdjustmentInvokesHoverIndexCallback() async throws {
        let callbacks = LightfieldComponentCallbacks()
        let size = CGSize(width: 520, height: 200)
        let host = lightfieldHost(root: LightfieldTrendChart(samples: LightfieldComponentGallery.samples,
            module: .memory, onHoverIndex: { callbacks.hoverIndex = $0 })
            .environment(\.featureDisablesLayoutAnimations, true), size: size, dark: true)
        defer { host.close() }
        let label = L10n.text("占用趋势", "Usage trend")
        try await host.waitForAccessibility(labels: [label])
        let object = try XCTUnwrap(host.element(label: label))
        let selector = NSSelectorFromString("accessibilityPerformDecrement")
        XCTAssertTrue(object.responds(to: selector), "History is adjustable through public AX")
        guard object.responds(to: selector) else { return }
        typealias NativeAction = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(object.method(for: selector))
        XCTAssertTrue(unsafeBitCast(implementation, to: NativeAction.self)(object, selector))
        XCTAssertEqual(callbacks.hoverIndex, 23)
        let expected = LightfieldComponentGallery.samples[23].time.formatted(date: .omitted, time: .standard) + " · 65.5%"
        try await host.waitForAccessibility(labels: [label], expectedValues: [label: expected])
        _ = try await host.frames(required: ["lightfield.trend.cursor", "fixture.viewport"], size: size)
    }

    /// Review P2-1/P2-9: after AX history adjustment the floating bubble is
    /// shown (180 wide, default style); a live refresh keeps the same moment
    /// and reports its new index instead of clearing the hover.
    func testTrendLiveRefreshKeepsTheHoveredMomentAndShowsTheBubble() async throws {
        let callbacks = LightfieldComponentCallbacks()
        let model = LightfieldTrendTestModel()
        let size = CGSize(width: 620, height: 200)
        let host = lightfieldHost(root: LightfieldTrendRefreshFixture(model: model, callbacks: callbacks), size: size, dark: true)
        defer { host.close() }
        let label = L10n.text("占用趋势", "Usage trend")
        try await host.waitForAccessibility(labels: [label])
        let object = try XCTUnwrap(host.element(label: label))
        let selector = NSSelectorFromString("accessibilityPerformDecrement")
        guard object.responds(to: selector) else { return XCTFail("History is adjustable through public AX") }
        typealias NativeAction = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(object.method(for: selector))
        XCTAssertTrue(unsafeBitCast(implementation, to: NativeAction.self)(object, selector))
        XCTAssertEqual(callbacks.hoverIndex, 23)
        let moment = LightfieldComponentGallery.samples[23]
        let expected = moment.time.formatted(date: .omitted, time: .standard) + " · 65.5%"
        try await host.waitForAccessibility(labels: [label], expectedValues: [label: expected])
        let frames = try await host.frames(required: ["lightfield.trend.bubble", "lightfield.trend.cursor", "fixture.viewport"], size: size)
        XCTAssertEqual(try XCTUnwrap(frames["lightfield.trend.bubble"]).width, 180, accuracy: 0.5)
        let last = try XCTUnwrap(LightfieldComponentGallery.samples.last)
        model.samples = Array(LightfieldComponentGallery.samples.dropFirst()) + [.init(time: last.time.addingTimeInterval(5), value: 0.4)]
        try await host.waitForAccessibility(labels: [label], expectedValues: [label: expected])
        XCTAssertEqual(callbacks.hoverIndex, 22, "Same moment, new index")
    }

    /// Review P2-2: performance run style — two lines with a series legend,
    /// no pressure bands, no Y axis and no current-value gutter.
    func testTrendMultiSeriesWithoutAxisOrGutterSpansTheChart() async throws {
        let size = CGSize(width: 520, height: 160)
        let gpu = LightfieldComponentGallery.samples.map { LightfieldTrendSample(time: $0.time, value: 0.04) }
        let host = lightfieldHost(root: LightfieldTrendChart(samples: LightfieldComponentGallery.samples, module: .performance,
            height: 48, title: "2 分钟 CPU / GPU 负载", primaryName: "CPU",
            series: [.init(id: "gpu", name: "GPU", color: .gray, samples: gpu)], legend: .series,
            showsPressureBands: false, axis: .hidden, fillsArea: false, showsCurrentValue: false)
            .layoutProbe("chart").frame(width: 520), size: size, dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["chart", "lightfield.trend.plot", "lightfield.trend.header",
            "lightfield.trend.series.gpu", "lightfield.trend.legend.CPU", "lightfield.trend.legend.GPU", "fixture.viewport"], size: size)
        let chart = try XCTUnwrap(frames["chart"])
        let plot = try XCTUnwrap(frames["lightfield.trend.plot"])
        XCTAssertEqual(plot.minX, chart.minX, accuracy: 0.5)
        XCTAssertEqual(plot.width, chart.width, accuracy: 0.5)
        XCTAssertEqual(plot.height, 48, accuracy: 0.5)
        XCTAssertNil(frames["lightfield.trend.axis"])
        for status in ["normal", "warning", "failure"] { XCTAssertNil(frames["lightfield.trend.band." + status]) }
        let last = try XCTUnwrap(LightfieldComponentGallery.samples.last)
        try await host.waitForAccessibility(labels: ["2 分钟 CPU / GPU 负载"], expectedValues: [
            "2 分钟 CPU / GPU 负载": last.time.formatted(date: .omitted, time: .standard) + " · 48.0% · GPU 4.0%"])
        let source = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldCharts.swift")
        XCTAssertTrue(source.contains("if showsPressureBands {"))
        XCTAssertTrue(source.contains("if dragged == nil { clearSelection() }"), "A click clears the range")
    }

    func testTrendMemoryDefaultAndCustomAxisKeepTheApproved96PointPlot() async throws {
        let size = CGSize(width: 620, height: 200)
        for axis in [LightfieldTrendAxis.percent, .labels(top: "32 GB", middle: "16 GB", bottom: "0 GB")] {
            let host = lightfieldHost(root: LightfieldTrendChart(samples: LightfieldComponentGallery.samples,
                module: .memory, title: "内存趋势", legend: .pressure, axis: axis,
                valueFormat: .scaledWithPercent(maximum: 32, unit: "GB"))
                .layoutProbe("chart").frame(width: 520), size: size, dark: true)
            defer { host.close() }
            let frames = try await host.frames(required: ["chart", "lightfield.trend.plot", "lightfield.trend.header",
                "lightfield.trend.axis", "lightfield.trend.band.normal", "lightfield.trend.band.warning",
                "lightfield.trend.band.failure", "fixture.viewport"], size: size)
            let chart = try XCTUnwrap(frames["chart"])
            let plot = try XCTUnwrap(frames["lightfield.trend.plot"])
            XCTAssertEqual(plot.height, 96, accuracy: 0.5)
            XCTAssertEqual(plot.minX - chart.minX, 42, accuracy: 0.5)
            XCTAssertEqual(chart.maxX - plot.maxX, 62, accuracy: 0.5)
            for status in ["normal", "warning", "failure"] {
                XCTAssertEqual(try XCTUnwrap(frames["lightfield.trend.band." + status]).height, 32, accuracy: 0.5)
            }
        }
        let plan = try text("docs/2.0.0/LIGHTFIELD-R2-PLAN.md")
        XCTAssertTrue(plan.contains("绘图区高 96、左轴 42、右侧当前值槽 62"))
    }

    func testDonutDimensionsCenterTextAndAccessibleLegend() async throws {
        let size = CGSize(width: 620, height: 200)
        let host = lightfieldHost(root: LightfieldDonutChart(items: LightfieldComponentGallery.chartItems,
            centerValue: "36.2 GB", centerLabel: "文件类型"), size: size, dark: false)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.donut", "lightfield.donut.text", "fixture.viewport"], size: size)
        let donut = try XCTUnwrap(frames["lightfield.donut"])
        XCTAssertEqual(donut.size, .init(width: 132, height: 132))
        XCTAssertTrue(donut.insetBy(dx: 14, dy: 14).contains(try XCTUnwrap(frames["lightfield.donut.text"])))
        try await host.waitForAccessibility(labels: ["36.2 GB · 文件类型"])
    }

    func testSummary76ArtworkAndAdjacentManagementNoteAcrossSevenWindows() async throws {
        for window in windows {
            let size = CGSize(width: window.width - 210, height: 200)
            let host = lightfieldHost(root: LightfieldSummary(module: .startup, label: "已发现",
                value: "12", unit: "项", note: "· 2 项可直接管理"), size: size, dark: true)
            defer { host.close() }
            let frames = try await host.frames(required: ["lightfield.summary", "lightfield.summary.art", "lightfield.summary.primary", "lightfield.summary.note", "fixture.viewport"], size: size)
            let summary = try XCTUnwrap(frames["lightfield.summary"])
            let primary = try XCTUnwrap(frames["lightfield.summary.primary"])
            let note = try XCTUnwrap(frames["lightfield.summary.note"])
            XCTAssertEqual(summary.height, 76, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(frames["lightfield.summary.art"]).size, .init(width: 76, height: 76))
            XCTAssertEqual(note.minX - primary.maxX, 12, accuracy: 0.5)
            XCTAssertTrue(summary.insetBy(dx: -0.5, dy: -0.5).contains(primary))
            XCTAssertTrue(summary.insetBy(dx: -0.5, dy: -0.5).contains(note))
        }
    }

    func testSummarySecondaryMetricsSitAtTheTrailingEdgeAcrossSevenWindows() async throws {
        for window in windows {
            let size = CGSize(width: window.width - 210, height: 200)
            let host = lightfieldHost(root: LightfieldSummary(module: .energy, label: "当前应用功率", value: "8.15", unit: "W",
                secondary: [.init(id: "a", label: "系统运行时间", value: "8", unit: "小时"),
                            .init(id: "b", label: "覆盖率", value: "86", unit: "%")]), size: size, dark: true)
            defer { host.close() }
            let frames = try await host.frames(required: ["lightfield.summary", "lightfield.summary.primary",
                "lightfield.summary.secondary.a", "lightfield.summary.secondary.b", "fixture.viewport"], size: size)
            let summary = try XCTUnwrap(frames["lightfield.summary"])
            // The summary spans its column, so "trailing" is the column's edge.
            XCTAssertEqual(summary.width, size.width, accuracy: 0.5, "\(window)")
            let first = try XCTUnwrap(frames["lightfield.summary.secondary.a"])
            let last = try XCTUnwrap(frames["lightfield.summary.secondary.b"])
            XCTAssertEqual(summary.maxX - last.maxX, 6, accuracy: 0.5, "\(window)")
            XCTAssertEqual(last.minX - first.maxX, 34, accuracy: 0.5, "\(window)")
            XCTAssertGreaterThanOrEqual(first.minX, try XCTUnwrap(frames["lightfield.summary.primary"]).maxX, "\(window)")
        }
    }

    func testGalleryArgumentAndAllTwelveFixturesPublishTheSharedSkeleton() async throws {
        XCTAssertTrue(LightfieldComponentGallery.requested(arguments: [LightfieldComponentGallery.launchArgument]))
        XCTAssertFalse(LightfieldComponentGallery.requested(arguments: []))
        XCTAssertFalse(LightfieldComponentGallery.requested(arguments: ["--debug-lightfield-gallery=1"]))
        XCTAssertEqual(LightfieldComponentGallery.components.count, 12)
        let session = LightfieldComponentGallerySession()
        let size = CGSize(width: 1070, height: 735)
        for component in LightfieldComponentGallery.components {
            session.component = component
            let host = lightfieldHost(root: LightfieldComponentGallery(session: session)
                .environment(\.featureDisablesLayoutAnimations, true), size: size, dark: true)
            defer { host.close() }
            let frames = try await host.frames(required: ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status", "fixture.viewport"], size: size)
            try assertCompactResultSkeleton(frames, window: .init(width: 1280, height: 763)) // D77 gallery/result
        }
    }

    func testEveryAnimatedComponentUsesReduceMotionAndSingleTimingOwner() throws {
        for name in ["FeatureLightfieldComponents.swift", "FeatureLightfieldCharts.swift"] {
            let source = try text("Sources/StorageCleanerMac/Views/DesignSystem/" + name)
            XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
            XCTAssertTrue(source.contains("reduceMotion: reduceMotion || disablesAnimations"))
            XCTAssertFalse(source.contains(".easeInOut(duration:"))
            XCTAssertFalse(source.contains(".linear(duration:"))
        }
        XCTAssertNil(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.check, reduceMotion: true))
        XCTAssertEqual(FeatureLightfieldMotion.duration(FeatureLightfieldMotion.halo, reduceMotion: true), 0)
        let source = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift")
        XCTAssertTrue(source.contains("TimelineView(.animation(paused: instant || !active))"))
        XCTAssertTrue(source.contains("content.opacity(instant || !active ? 1 :"))
    }

    /// The shared host publishes `fixture.viewport` on the root as given. A bare
    /// component is intrinsically sized, so give it the viewport (top-leading)
    /// exactly as page fixtures do; sizes inside the component are unchanged.
    private func lightfieldHost<Root: View>(root: Root, size: CGSize, dark: Bool) -> CalibrationAppKitLayoutHost {
        CalibrationAppKitLayoutHost(root: root.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
            size: size, dark: dark)
    }

    private func text(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

@MainActor private final class LightfieldComponentCallbacks {
    var selected = true
    var highlighted: String?
    var drilled: String?
    var hoverIndex: Int?
}
@MainActor private final class LightfieldTrendTestModel: ObservableObject {
    @Published var samples = LightfieldComponentGallery.samples
}
private struct LightfieldTrendRefreshFixture: View {
    @ObservedObject var model: LightfieldTrendTestModel
    let callbacks: LightfieldComponentCallbacks
    var body: some View {
        LightfieldTrendChart(samples: model.samples, module: .memory, onHoverIndex: { callbacks.hoverIndex = $0 })
            .frame(width: 520)
    }
}
private struct LightfieldOptionTestFixture: View {
    @State private var selected = true
    let callbacks: LightfieldComponentCallbacks
    var body: some View {
        VStack(spacing: 0) {
            LightfieldOptionRow(title: "选择范围", icon: .cleanupSystemCache, module: .green, selection: $selected, probeID: "option")
            LightfieldOptionRow(title: "固定项目", icon: .benchmarkCpu, module: .performance, metadata: "6 项", probeID: "fixed")
        }.onChange(of: selected) { _, value in callbacks.selected = value }
    }
}
private struct LightfieldExpansionTestFixture: View {
    @State private var expanded = false
    var body: some View {
        LightfieldExpandableRow(title: "展开行", expanded: $expanded) {
            LightfieldAppIcon(size: .medium)
        } content: { Text("子行").layoutProbe("child") }
        .layoutProbe("expandable")
    }
}
private struct LightfieldSegmentsTestFixture: View {
    @State private var selection = 0
    var body: some View { LightfieldTextSegments(titles: ["全部", "登录时打开", "后台运行"], selection: $selection, module: .startup) }
}
#endif
