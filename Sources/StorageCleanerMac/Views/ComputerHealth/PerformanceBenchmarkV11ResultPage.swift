import SwiftUI

struct PerformanceBenchmarkV11ResultPage: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings
    private let compactResults = FeatureLightfield.usesResultSpace(.performance)
    let result: BenchmarkV7Result
    let history: [BenchmarkV7Result]
    let catalog: AppleSiliconCatalogLoader.Loaded
    let canStart: Bool
    let onStart: () -> Void
    let onOpenHistory: (BenchmarkV7Result) -> Void
    var onExport: (BenchmarkV7Result) -> Void = { _ in }
    var saveState: MSeriesV11SaveState? = nil
    var initialSection = 0
    @State private var section = 0
    @State private var sustainedSelection = 0
    @State private var expandedGroups: Set<String> = ["cpu.single", "cpu.multi", "gpu", "memory", "storage"]
    private var palette: FeatureLightfieldPalette { .resolve(scheme) }
    private var sectionTitles: [String] { [L10n.text("概览", "Overview"), L10n.text("档案", "Profile"),
        L10n.text("原始值", "Raw values"), L10n.text("加速单元", "Accelerators"), L10n.text("历史", "History"), L10n.text("社区榜", "Community")] }
    private let anchors = ["overview", "profile", "raw", "accelerators", "history", "community"]
    private var disposition: MSeriesV11PagePresentation.ResultDisposition { .init(result: result, history: history, saveState: saveState) }
    var body: some View {
        if let envelope = result.mSeriesV11 {
            FeatureLightfieldPage(module: .performance, phase: .result, title: ReviewFilter.performance.sidebarTitle,
                status: MSeriesV11PagePresentation.referenceExplanation(envelope),
                safety: disposition.storageText + " · " + L10n.text("社区暂不可提交", "Community unavailable"),
                actionTitle: L10n.text("重新测试", "Test again"), actionEnabled: canStart, action: onStart,
                subtitle: disposition.completionText, subtitleAccessory: AnyView(LightfieldTextSegments(titles: sectionTitles, selection: $section, module: .performance, spacing: 16, height: 20))) {
                    FeatureLightfieldPlacementReader { _, hasHeaderTabs in
                    GeometryReader { proxy in
                        let layout = MSeriesV11PagePresentation.ResultLayout(width: proxy.size.width, height: proxy.size.height)
                        let pinsSummary = compactResults || layout.pinsSummary
                        VStack(alignment: .leading, spacing: 0) {
                            if pinsSummary {
                                summary(envelope, width: proxy.size.width)
                                    .frame(height: compactResults ? 0 : layout.summaryHeight).padding(.bottom, compactResults ? 0 : 24)
                            }
                            ScrollViewReader { reader in
                                ScrollView(.vertical) {
                                    VStack(alignment: .leading, spacing: 16) {
                                        if !pinsSummary { summary(envelope, width: proxy.size.width) }
                                        if !hasHeaderTabs { LightfieldTextSegments(titles: sectionTitles, selection: $section, module: .performance, spacing: 16) }
                                        if compactResults && proxy.size.width < 600 {
                                            // Three score columns cannot fit the narrow header
                                            // at the approved minimum numeric scale. Both
                                            // secondary scores remain visible in the details.
                                            HStack(spacing: 16) {
                                                ForEach(["system", "efficiency"], id: \.self) { id in
                                                    FeatureLightfieldCompactMetric(value: MSeriesV11PagePresentation.ScoreDisplay(id: id, result: envelope).metric,
                                                        module: .performance, probe: "performance.summary.secondary." + id,
                                                        valueProbe: "performance.summary.secondary.value." + id)
                                                }
                                            }.frame(height: 48)
                                        }
                                        if compactResults {
                                            Text(MSeriesV11PagePresentation.referenceCaption(envelope))
                                                .font(.system(size: 12)).foregroundStyle(palette.fg2)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .lightfieldComponentProbe("performance.summary.caption")
                                        }
                                        if compactResults && !MSeriesV11PagePresentation.hasMeasuredEfficiency(envelope) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(MSeriesV11PagePresentation.helperRequired).font(.system(size: 13)).foregroundStyle(palette.fg2)
                                                    .lightfieldComponentProbe("performance.helper.required.summary")
                                                Button(L10n.text("去设置 · 系统助手", "Settings · System Helper"), action: helperSettings)
                                                    .buttonStyle(FeatureLightfieldRowButtonStyle()).font(.system(size: 13))
                                                    .foregroundStyle(FeatureLightfieldPalette.accent(.performance))
                                                    .lightfieldComponentProbe("performance.helper.settings.summary")
                                            }
                                        }
                                        if let termination = disposition.terminationText {
                                            Text(termination).font(.system(size: 13)).foregroundStyle(palette.warningColor)
                                                .fixedSize(horizontal: false, vertical: true).lightfieldComponentProbe("performance.termination")
                                        }
                                        if let storage = disposition.saveFailureText {
                                            Text(storage).font(.system(size: 13)).foregroundStyle(palette.warningColor)
                                                .fixedSize(horizontal: false, vertical: true).lightfieldComponentProbe("performance.saveFailure")
                                        }
                                        ForEach(["chip", "system", "efficiency"].map { MSeriesV11PagePresentation.ScoreDisplay(id: $0, result: envelope) }) { display in
                                            if let reason = display.reason {
                                                Text(display.metric.label + " · " + reason).font(.system(size: 13)).foregroundStyle(palette.fg3)
                                                    .fixedSize(horizontal: false, vertical: true).lightfieldComponentProbe("performance.restricted." + display.id)
                                            }
                                        }
                                        overview(envelope, width: proxy.size.width).id("overview")
                                        Text(MSeriesV11PagePresentation.referenceExplanation(envelope))
                                            .font(.system(size: 13)).foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true)
                                        gpuEfficiency(envelope)
                                        profile(envelope).id("profile")
                                        rawValues(width: proxy.size.width).id("raw")
                                        accelerators(envelope).id("accelerators")
                                        PerformanceBenchmarkV11HistoryList(history: history, current: result, onOpen: onOpenHistory).id("history")
                                        VStack(alignment: .leading, spacing: 6) {
                                            heading(L10n.text("社区榜", "Community"))
                                            Text(MSeriesV11PagePresentation.community)
                                            Text(L10n.text("匿名上传：关闭", "Anonymous upload: off")).foregroundStyle(palette.fg2)
                                        }.font(.system(size: 13)).id("community").lightfieldComponentProbe("performance.community")
                                        Button(L10n.text("导出本次原始结果", "Export raw result")) { onExport(result) }
                                            .buttonStyle(FeatureLightfieldRowButtonStyle()).foregroundStyle(palette.fg2)
                                            .font(.system(size: 13)).padding(.bottom, 16)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.scrollIndicators(.hidden).lightfieldComponentProbe("performance.result.scroll")
                                    .onAppear { section = min(anchors.count - 1, max(0, initialSection)); if section > 0 { reader.scrollTo(anchors[section], anchor: .top) } }
                                    .onChange(of: section) { _, index in reader.scrollTo(anchors[index], anchor: .top) }
                            }
                        }.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    }
                    }
                }
        }
    }
    @ViewBuilder private func summary(_ envelope: MSeriesV11Result, width: CGFloat) -> some View {
        if compactResults {
            let chip = MSeriesV11PagePresentation.ScoreDisplay(id: "chip", result: envelope).metric
            LightfieldSummary(module: .performance, label: chip.label, value: chip.value, unit: chip.unit,
                secondary: width >= 600 ? ["system", "efficiency"].map { MSeriesV11PagePresentation.ScoreDisplay(id: $0, result: envelope).metric } : [],
                showsArtwork: false, probeID: "performance.summary", primaryCaption: MSeriesV11PagePresentation.referenceCaption(envelope),
                valuePrefix: chip.valuePrefix, primaryStatus: chip.status)
        } else {
            regularSummary(envelope, width: width)
        }
    }
    private func regularSummary(_ envelope: MSeriesV11Result, width: CGFloat) -> some View {
        let caption = MSeriesV11PagePresentation.referenceCaption(envelope)
        let chip = MSeriesV11PagePresentation.ScoreDisplay(id: "chip", result: envelope).metric
        let metrics = ["system", "efficiency"].map { MSeriesV11PagePresentation.ScoreDisplay(id: $0, result: envelope).metric }
        return VStack(alignment: .leading, spacing: 8) {
            LightfieldSummary(module: .performance, label: L10n.text("芯片性能分", "Chip performance score"),
                value: chip.value, unit: "",
                secondary: width >= 740 ? metrics : [], showsArtwork: false, probeID: "performance.summary", primaryCaption: caption, valuePrefix: chip.valuePrefix, secondaryColumnWidth: width >= 740 ? min(196, width * 0.224) : nil, primaryStatus: chip.status)
            if width < 740 {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(metrics) { metric in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.label).font(.system(size: 13)).foregroundStyle(palette.fg2)
                            (Text(metric.valuePrefix).font(.system(size: 13)).foregroundColor(palette.fg2) + Text(metric.value).font(.system(size: 22, weight: .semibold)).foregroundColor(metric.status?.color(palette) ?? palette.fg)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: result-secondary
                            Text(metric.caption).font(.system(size: 11)).foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).lightfieldComponentProbe("performance.summary.secondary." + metric.id)
                    }
                }
            }
        }.foregroundStyle(palette.fg).overlay(alignment: .bottomTrailing) {
            if !MSeriesV11PagePresentation.hasMeasuredEfficiency(envelope) {
                Button(L10n.text("去设置 · 系统助手", "Settings · System Helper"), action: helperSettings)
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.accent(.performance))
                    .lightfieldComponentProbe("performance.helper.settings.summary")
                    .frame(width: width >= 740 ? min(196, width * 0.224) + 6 : (width - 16) / 2, alignment: .leading)
                    .zIndex(1)
            }
        }
        // Keep the real settings control separate from the summary's combined
        // text node, including when only its bottom is visible in a short scroll.
        .accessibilityElement(children: .contain)
        .lightfieldComponentProbe("performance.summary.container")
    }
    private func overview(_ envelope: MSeriesV11Result, width: CGFloat) -> some View {
        let ids = ["cpuSingle", "cpuMulti", "gpuPeak", "gpuSustained"]
        let names = [L10n.text("CPU 单核", "CPU single"), L10n.text("CPU 多核", "CPU multi"), L10n.text("GPU 峰值", "GPU peak"), L10n.text("GPU 持续", "GPU sustained")]
        let ratioLayout = MSeriesV11PagePresentation.RatioLayout(availableWidth: width)
        let maximum = max(4, ids.compactMap { MSeriesV11PagePresentation.ratio($0, result: envelope) }.max() ?? 4)
        return VStack(alignment: .leading, spacing: 12) {
            FeatureLightfieldHairline()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(ratioLayout.columnWidth), spacing: ratioLayout.gap), count: ratioLayout.count), alignment: .leading, spacing: 12) {
                ForEach(ids.indices, id: \.self) { index in
                    let ratio = MSeriesV11PagePresentation.ratio(ids[index], result: envelope)
                    let restricted = MSeriesV11PagePresentation.scoreRestricted(ids[index], result: envelope)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if ratio != nil { Text(names[index]).font(.system(size: 13)).lineLimit(1); Spacer(minLength: 0) }
                            Text(ratio.map { MSeriesV11PagePresentation.number($0, digits: 2) + "×" } ?? MSeriesV11PagePresentation.calibration)
                                .font(.system(size: 17, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: result-ratio
                                .frame(maxWidth: ratio == nil ? .infinity : nil, alignment: .leading)
                                .foregroundStyle(restricted ? palette.fg3 : palette.fg)
                                .lightfieldComponentProbe("performance.ratio." + ids[index])
                        }
                        if ratio == nil { Text(names[index]).font(.system(size: 13)).foregroundStyle(palette.fg2).lineLimit(1) }
                        LightfieldDataBar(progress: ratio.map { $0 / maximum }, module: .performance, status: restricted ? .unknown : nil)
                            .overlay { GeometryReader { proxy in
                                Rectangle().fill(palette.fg2).frame(width: 1, height: 8).offset(x: proxy.size.width / maximum, y: -3)
                            }.accessibilityHidden(true) }
                        Text(MSeriesV11PagePresentation.referenceCaption(envelope)).font(.system(size: 11))
                            .foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(width: ratioLayout.fittedWidth, alignment: .leading)
            Text(L10n.text("标记线＝参考 1× · 图示范围 0–\(Int(ceil(maximum)))×", "Marker = reference 1× · Range 0–\(Int(ceil(maximum)))×"))
                .font(.system(size: 12)).foregroundStyle(palette.fg2)
            if width >= 740 {
                HStack(alignment: .top, spacing: 24) {
                    cpuEfficiency(envelope).frame(maxWidth: .infinity)
                    sustained(envelope).frame(maxWidth: .infinity)
                }
            } else { cpuEfficiency(envelope); sustained(envelope) }
        }.foregroundStyle(palette.fg)
    }
    private func cpuEfficiency(_ envelope: MSeriesV11Result) -> some View {
        let points = envelope.efficiencyPoints.filter { $0.id.hasPrefix("power.cpu.") && MSeriesV11PagePresentation.measuredEfficiencyPoint($0, in: envelope) && $0.throughput?.statistics != nil }.sorted { ($0.meanPowerW ?? 0) < ($1.meanPowerW ?? 0) }
        return VStack(alignment: .leading, spacing: 8) {
            heading(L10n.text("能效曲线 · CPU", "Efficiency curve · CPU"))
            if points.isEmpty {
                Text(MSeriesV11PagePresentation.helperRequired).font(.system(size: 20, weight: .semibold)).padding(.top, 24)
                Text(L10n.text("无法取得有效实测功率区间；能效分与曲线暂不可用。", "No valid measured power interval; efficiency score and curve unavailable."))
                    .font(.system(size: 13)).foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("去设置 · 系统助手", "Settings · System Helper"), action: helperSettings)
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).foregroundStyle(FeatureLightfieldPalette.accent(.performance)).font(.system(size: 13))
                    .lightfieldComponentProbe("performance.helper.settings.curve")
            } else {
                let powerMax = max(10, (points.compactMap(\.meanPowerW).max() ?? 0) * 1.1)
                let throughputMax = max(1, (points.compactMap { $0.throughput?.statistics?.median }.max() ?? 0) * 1.1)
                Text(MSeriesV11PagePresentation.unit("fixed-fixtures/s")).font(.system(size: 12)).foregroundStyle(palette.fg2)
                LightfieldTrendChart(samples: points.enumerated().map { .init(time: Date(timeIntervalSinceReferenceDate: Double($0.offset)),
                    value: ($0.element.throughput?.statistics?.median).map { $0 / throughputMax }) }, module: .performance, height: 90,
                    showsPressureBands: false, axis: .labels(top: MSeriesV11PagePresentation.number(throughputMax, digits: 0), middle: MSeriesV11PagePresentation.number(throughputMax / 2, digits: 0), bottom: "0"),
                    fillsArea: false, showsCurrentValue: false, valueFormat: .scaled(maximum: throughputMax, unit: MSeriesV11PagePresentation.unit("fixed-fixtures/s")),
                    xFractions: points.map { ($0.meanPowerW ?? 0) / powerMax }, xAxisLabels: ("0 W", MSeriesV11PagePresentation.number(powerMax) + " W"), xValueFormat: .scaled(maximum: powerMax, unit: "W"), showsPoints: true,
                    pointLabels: points.map { ($0.resolvedWorkers.map(String.init) ?? MSeriesV11PagePresentation.unread) + L10n.text("线程", " threads") }, probeID: "performance.efficiency.chart")
                Text(L10n.text("CPU 报告功率口径", "CPU reported power") + " · " + points.map {
                    ($0.resolvedWorkers.map(String.init) ?? MSeriesV11PagePresentation.unread) + L10n.text("线程", " threads")
                }.joined(separator: " / ")).font(.system(size: 12)).foregroundStyle(palette.fg2)
                let all = points.first { $0.id == "power.cpu.allCores" }
                Text(L10n.text("全核每瓦性能", "All core performance per watt") + " · " + MSeriesV11PagePresentation.number(all?.efficiency?.statistics?.median)
                    + " " + MSeriesV11PagePresentation.unit("fixed-fixtures/J")).font(.system(size: 12)).foregroundStyle(palette.fg2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).lightfieldComponentProbe("performance.efficiency")
    }
    private func sustained(_ envelope: MSeriesV11Result) -> some View {
        let measured = sustainedSelection == 0 ? envelope.sustainedCPU : envelope.sustainedGPU
        let gpu = sustainedSelection == 1
        let unit = MSeriesV11PagePresentation.unit(gpu ? "Mtri/s" : "fixed-fixtures/s")
        let values = measured?.windows.map { gpu ? $0.gpuTimedThroughput : $0.wallThroughput } ?? []
        let maximum = max(1, (values.compactMap { $0 }.max() ?? 0) * 1.1)
        let windows = measured?.windows ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                heading(L10n.text("持续性能", "Sustained performance"))
                Spacer(minLength: 0)
                LightfieldTextSegments(titles: ["CPU", "GPU"], selection: $sustainedSelection, module: .performance)
            }
            Text(unit).font(.system(size: 12)).foregroundStyle(palette.fg2)
            if windows.isEmpty { Text(MSeriesV11PagePresentation.unread).font(.system(size: 15)).padding(.vertical, 24) }
            else {
                LightfieldTrendChart(samples: windows.enumerated().map { .init(time: Date(timeIntervalSinceReferenceDate: $0.element.elapsedSeconds), value: values[$0.offset].map { $0 / maximum }) },
                    module: .performance, height: 90, primaryName: L10n.text("吞吐", "Throughput"), series: [.init(id: "temperature", name: L10n.text("温度", "Temperature"), color: palette.warningColor,
                        samples: windows.map { .init(time: Date(timeIntervalSinceReferenceDate: $0.elapsedSeconds), value: $0.temperatureC.map { $0 / 100 }) })],
                    legend: .series, showsPressureBands: false, axis: .labels(top: MSeriesV11PagePresentation.number(maximum, digits: 0), middle: MSeriesV11PagePresentation.number(maximum / 2, digits: 0), bottom: "0"),
                    fillsArea: false, showsCurrentValue: false, valueFormat: .scaled(maximum: maximum, unit: unit),
                    xFractions: windows.map { $0.elapsedSeconds / max(1, measured?.durationSeconds ?? 90) },
                    xAxisLabels: ("0 " + L10n.text("秒", "s"), MSeriesV11PagePresentation.number(measured?.durationSeconds, digits: 0) + " " + L10n.text("秒", "s")),
                    xValueFormat: .scaled(maximum: measured?.durationSeconds ?? 90, unit: L10n.text("秒", "s")),
                    secondaryAxis: .labels(top: "100°C", middle: "50°C", bottom: "0°C"), secondaryValueFormat: .scaled(maximum: 100, unit: "°C"), probeID: "performance.sustained.chart")
            }
            Text(L10n.text("保持率", "Retention") + " · " + ((measured?.retention).map { MSeriesV11PagePresentation.number($0 * 100) + "%" } ?? MSeriesV11PagePresentation.unread))
                .font(.system(size: 13, weight: .semibold))
            Text(L10n.text("末 30 秒 / 首 10 秒中位数", "Last 30 s / first 10 s median") + " · \(ByteFormat.count(windows.count)) " + L10n.text("个五秒窗口", "five second windows"))
                .font(.system(size: 12)).foregroundStyle(palette.fg2)
        }.frame(maxWidth: .infinity, alignment: .leading).lightfieldComponentProbe("performance.sustained")
    }
    private func gpuEfficiency(_ envelope: MSeriesV11Result) -> some View {
        let point = envelope.efficiencyPoints.first { $0.id == "power.gpu.peak" && MSeriesV11PagePresentation.measuredEfficiencyPoint($0, in: envelope) }
        return VStack(alignment: .leading, spacing: 8) {
            heading(L10n.text("GPU 能效观察 · 独立墙钟区间", "GPU efficiency · Independent wall interval"))
            if let point {
                LightfieldMetricGroup(metrics: [.init(id: "power", label: L10n.text("GPU 功率", "GPU power"), value: MSeriesV11PagePresentation.number(point.meanPowerW), unit: "W"),
                    .init(id: "efficiency", label: L10n.text("每焦吞吐", "Throughput per joule"), value: MSeriesV11PagePresentation.number(point.efficiency?.statistics?.median), unit: MSeriesV11PagePresentation.unit("Mtri/J"))])
                let watts = point.meanPowerW ?? 0
                let throughput = (point.matchedWorkUnits ?? 0) / max(0.000_001, point.observedSeconds ?? 0)
                let maximumPower = max(1, watts * 1.2)
                let maximumThroughput = max(1, throughput * 1.2)
                LightfieldTrendChart(samples: [.init(time: Date(timeIntervalSinceReferenceDate: 0), value: throughput / maximumThroughput)],
                    module: .performance, height: 90, title: L10n.text("GPU 报告功率 · 对齐墙钟吞吐", "GPU reported power · Aligned wall throughput"), showsPressureBands: false,
                    axis: .labels(top: MSeriesV11PagePresentation.number(maximumThroughput), middle: MSeriesV11PagePresentation.number(maximumThroughput / 2), bottom: "0"),
                    fillsArea: false, showsCurrentValue: false, valueFormat: .scaled(maximum: maximumThroughput, unit: MSeriesV11PagePresentation.unit("Mtri/s")),
                    xFractions: [watts / maximumPower], xAxisLabels: ("0 W", MSeriesV11PagePresentation.number(maximumPower) + " W"), xValueFormat: .scaled(maximum: maximumPower, unit: "W"), showsPoints: true)
                Text(L10n.text("本次仅一个 GPU 实测点，不插值成参考曲线", "One measured GPU point; no inferred reference curve")).font(.system(size: 12)).foregroundStyle(palette.fg2)
            } else { Text(MSeriesV11PagePresentation.helperRequired).font(.system(size: 13)).foregroundStyle(palette.fg2) }
        }
    }
    private func profile(_ envelope: MSeriesV11Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureLightfieldHairline()
            heading(L10n.text("芯片档案", "Chip profile"))
            Text(MSeriesV11PagePresentation.chipLine(envelope.hardwareIdentity, catalog: catalog)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if MSeriesV11PagePresentation.catalogMatches(envelope.hardwareIdentity, catalog), let chip = catalog.catalog?.chips.first(where: { $0.id == envelope.hardwareIdentity?.chipID }) {
                let sku = envelope.hardwareIdentity?.matchedSKU
                Text(L10n.text("当前配置带宽：", "Current SKU bandwidth: ") + MSeriesV11PagePresentation.number(sku?.memoryBandwidthGBps) + " GB/s")
                    .font(.system(size: 13)).foregroundStyle(palette.fg2)
                heading(L10n.text("同代理论位置 · 规格位置，非实测", "Same generation · Specification position, not measured"))
                specificationBars(chip)
                if !chip.unverified.isEmpty { Text(L10n.text("部分规格未核实，缺值保持未知。", "Some specifications remain unverified and unknown.")).font(.system(size: 12)).foregroundStyle(palette.fg2) }
            } else { Text(L10n.text("目录缺失或与记录版本不符 · 规格未读取", "Catalog missing or version differs · Specifications not read")).font(.system(size: 13)).foregroundStyle(palette.fg2) }
        }.foregroundStyle(palette.fg)
    }
    private func specificationBars(_ chip: AppleSiliconCatalog.Chip) -> some View {
        let generation = chip.id.split(separator: "-").first.map(String.init) ?? chip.id
        let chips = catalog.catalog?.chips.filter { $0.id.split(separator: "-").first.map(String.init) == generation } ?? []
        let verifiedRows = chips.flatMap { peer in
            peer.skus.indices.flatMap { MSeriesV11PagePresentation.specificationRows(peer, skuIndex: $0) }
        }
        let cpuMax = verifiedRows.filter { $0.title == "CPU" }.compactMap(\.value).max() ?? 1
        let gpuMax = verifiedRows.filter { $0.title == "GPU" }.compactMap(\.value).max() ?? 1
        let bandwidthMax = verifiedRows.filter { $0.title == "GB/s" }.compactMap(\.value).max() ?? 1
        return VStack(spacing: 12) {
            ForEach(chips, id: \.id) { peer in
                ForEach(peer.skus.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(peer.marketingName + " · " + peer.skus[index].id).font(.system(size: 13))
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(MSeriesV11PagePresentation.specificationRows(peer, skuIndex: index)) { row in
                                specificationBar(row, maximum: row.title == "CPU" ? cpuMax : row.title == "GPU" ? gpuMax : bandwidthMax)
                            }
                        }
                    }
                }
            }
        }
    }
    private func specificationBar(_ row: MSeriesV11PagePresentation.SpecificationRow, maximum: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title + " " + MSeriesV11PagePresentation.number(row.value, digits: 0)).font(.system(size: 12)).monospacedDigit().lineLimit(1)
            LightfieldDataBar(progress: row.value.map { $0 / maximum }, module: .performance)
            ForEach(row.sources, id: \.absoluteString) { url in
                Link(row.sourceLabel + " · " + (url.host ?? ""), destination: url)
                    .font(.system(size: 11)).foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true)
            }
            if let reason = row.unknownReason {
                Text(MSeriesV11PagePresentation.unread + " · " + reason).font(.system(size: 11)).foregroundStyle(palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .lightfieldComponentProbe("performance.specification." + row.id)
    }
    private func rawValues(width: CGFloat) -> some View {
        let previous = MSeriesV11PagePresentation.previousCore(for: result, history: history)
        return VStack(alignment: .leading, spacing: 0) {
            heading(L10n.text("18 项原始值", "18 raw measurements")).padding(.bottom, 8)
            Text(L10n.text("中位数 · 稳定度 A/B/C 为样本稳定程度，非置信度", "Median · Stability A/B/C describes samples, not confidence"))
                .font(.system(size: 12)).foregroundStyle(palette.fg2).padding(.bottom, 8)
            ForEach(["cpu.single", "cpu.multi", "gpu", "memory", "storage"], id: \.self) { group in
                LightfieldExpandableRow(title: groupTitle(group), expanded: Binding(get: { expandedGroups.contains(group) },
                    set: { if $0 { expandedGroups.insert(group) } else { expandedGroups.remove(group) } })) { EmptyView() } content: {
                        ForEach(MSeriesProtocol.coreIDs.filter { $0.hasPrefix(group + ".") }, id: \.self) { id in
                            PerformanceBenchmarkV11RawRow(id: id, metric: result.mSeries?.metrics.first { $0.id == id },
                                previous: previous?.mSeries?.metrics.first { $0.id == id }, wide: width >= 820,
                                currentResult: result, previousResult: previous)
                        }
                    }
            }
        }
    }
    private func groupTitle(_ group: String) -> String {
        switch group {
        case "cpu.single": L10n.text("CPU 单线程 · 4 项", "CPU single thread · 4")
        case "cpu.multi": L10n.text("CPU 多线程 · 4 项", "CPU multi thread · 4")
        case "gpu": "GPU · 3 " + L10n.text("项", "items")
        case "memory": L10n.text("内存 · 3 项", "Memory · 3")
        default: L10n.text("存储 · 4 项", "Storage · 4")
        }
    }
    private func accelerators(_ envelope: MSeriesV11Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.text("加速单元 · 独立展示，不计分", "Accelerators · Independent, unscored"))
            if envelope.accelerators.isEmpty { Text(L10n.text("本次未选择加速单元", "Accelerators not selected")).font(.system(size: 13)).foregroundStyle(palette.fg2) }
            ForEach(Array(envelope.accelerators.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    Text(MSeriesV11PagePresentation.itemTitle(item.id)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(MSeriesV11PagePresentation.availability(item.availability, reason: item.reasonCode))
                    if let metric = item.metric, item.availability == "available" {
                        Text(MSeriesV11PagePresentation.number(metric.statistics?.median) + " " + MSeriesV11PagePresentation.unit(metric.contract.unit)).monospacedDigit()
                    }
                }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
            }
            Text(L10n.text("神经网络引擎 · 阶段 2", "Neural Engine · Phase 2")).font(.system(size: 13)).foregroundStyle(palette.fg3)
        }
    }
    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.fg).accessibilityAddTraits(.isHeader) }
    private func helperSettings() { SystemHelperSettingsNavigation.shared.requestID = UUID(); openSettings() }
}
