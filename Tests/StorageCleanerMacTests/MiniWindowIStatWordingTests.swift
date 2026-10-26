#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D138: the titles, ring labels, history titles and tooltip rows take iStat
/// Menus 7.30's words, looked up key by key in BBRMenuKit's and
/// BBRStatisticsKit's zh-CN and en tables (`R9-wording-evidence.txt`). The
/// case was already iStat's: section headers, ring labels and history titles
/// draw upper case. Runtime checks where a model or a static gives the words;
/// source contracts, scoped to one view, where a view body holds them. No
/// window, no user data.
@MainActor
final class MiniWindowIStatWordingTests: XCTestCase {
    /// `-[BBRMemoryMenuMemorySection values]`: 'Memory.App', 'Memory.Wired',
    /// 'Memory.Compressed' and 'Memory.Free'. The level-two rows, the
    /// composition history's rows and its tooltip rows all read
    /// `GeekMemoryComponent.title`; the history is titled 'Memory.Memory'.
    func testMemoryCompositionUsesIStatsNames() throws {
        eachLanguage { chinese in
            XCTAssertEqual(GeekMemoryComponent.allCases.map(\.title),
                           chinese ? ["App内存", "联动内存", "已压缩", "可用"] : ["App", "Wired", "Compressed", "Free"])
        }
        let composition = try Self.source("Views/MenuBarAdvanced/GeekMemoryCompositionView.swift")
        let history = try Self.body(of: "struct GeekMemoryCompositionHistoryDetail: View {", in: composition)
        XCTAssertTrue(history.contains("title: L10n.text(\"内存\", \"Memory\"),"))
        XCTAssertTrue(history.contains("MenuBarTelemetrySeries(id: $0.id, title: $0.title, channel: $0.channel"))
        XCTAssertFalse(composition.contains("L10n.text(\"内存组成占比\""))
        XCTAssertTrue(try Self.body(of: "struct GeekMemoryCompositionIStatRows: View {", in: composition)
            .contains("title: component.title,"))
    }

    /// The rings: the memory header's 'Memory.Memory' (the pressure ring
    /// keeps 压力, deviation 1), the GPU's 'GPU.MEMShort' and 'Units.GHz'
    /// (always, also without a reading), the battery's 'Power.HealthShort'.
    /// The GPU memory's long name, 'GPU.Memory', is the history's row and
    /// the ring's VoiceOver title.
    func testRingLabelsUseIStatsNames() throws {
        eachLanguage { chinese in
            XCTAssertEqual(GeekGPUVocabulary.memoryRingTitle, chinese ? "内存" : "MEM")
            XCTAssertEqual(GeekGPUVocabulary.memory, chinese ? "内存" : "Memory")
        }
        let overview = try Self.source("Views/MenuBarAdvanced/GeekOverviewPresentation.swift")
        let memoryPage = try Self.source("Views/MenuBarAdvanced/GeekMemoryView.swift")
        let levelOne = try Self.body(of: "struct GeekMemoryPresentation: View {", in: overview)
        let levelTwo = try MiniWindowLogicFixtures.section(
            memoryPage, from: "private var geekMemoryRingsCard: some View {", to: "private var geekMemoryProcessesCard")
        for rings in [levelOne, levelTwo] {
            XCTAssertTrue(rings.contains("title: L10n.text(\"内存\", \"Memory\"),"))
            XCTAssertFalse(rings.contains("L10n.text(\"占用\", \"Used\")"))
        }
        XCTAssertTrue(levelOne.contains("title: L10n.text(\"压力\", \"Pressure\"),"))

        let processor = try Self.source("Views/MenuBarAdvanced/GeekProcessorView.swift")
        let frequencyRing = try MiniWindowLogicFixtures.section(
            processor, from: "private var geekProcessorGPUFrequencyRing: some View {",
            to: "private var geekProcessorGPUHoverTarget")
        XCTAssertTrue(frequencyRing.contains("title: \"GHz\","))
        XCTAssertFalse(processor.contains("L10n.text(\"频率\", \"FREQ\")"))
        XCTAssertNil(GeekGPUFrequencyPresentation.ringValue(nil).unit, "the label does not wait for a reading")
        XCTAssertTrue(processor.contains("title: GeekGPUVocabulary.memoryRingTitle,"))
        XCTAssertTrue(processor.contains("accessibilityTitle: GeekGPUVocabulary.memory"))
        let detail = try Self.source("Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        XCTAssertTrue(try Self.body(of: "struct GeekGPUHoverDetail: View {", in: detail)
            .contains("title: GeekGPUVocabulary.memory,"))

        let power = try Self.source("Views/MenuBarAdvanced/GeekPowerView.swift")
        XCTAssertTrue(power.contains("title: L10n.text(\"健康\", \"HEALTH\"),"))
        XCTAssertFalse(power.contains("L10n.text(\"电池健康\", \"HEALTH\")"))
    }

    /// The level-two section titles: 'CPU.Load', 'CPU.Uptime', 'Memory.Swap',
    /// 'Disks.Network Disks', the sensor groups' names
    /// (`-[BBRStatisticsSensors nameForGroup:]`: 'Sensors.Amperage' and
    /// 'Sensors.Light'), 'Power.Using Significant Energy', and the disk
    /// activity's 'Disks.Read' and 'Disks.Write'.
    func testSectionTitlesUseIStatsWords() throws {
        let processor = try Self.source("Views/MenuBarAdvanced/GeekProcessorView.swift")
        XCTAssertTrue(processor.contains(
            "GeekIStatSingleRowCard(title: L10n.text(\"平均负载量\", \"LOAD\"), value: geekProcessorLoadText)"))
        XCTAssertTrue(processor.contains(
            "GeekIStatSingleRowCard(title: L10n.text(\"电脑开启时间\", \"UPTIME\"), value: uptimeText)"))

        let memory = try Self.source("Views/MenuBarAdvanced/GeekMemoryView.swift")
        XCTAssertTrue(memory.contains("Text(L10n.text(\"已使用的交换\", \"Swap\"))"))
        XCTAssertTrue(memory.contains(".accessibilityLabel(L10n.text(\"已使用的交换\", \"Swap\"))"))
        XCTAssertFalse(memory.contains("L10n.text(\"交换内存\", \"Swap Memory\")"))

        let disk = try Self.source("Views/MenuBarAdvanced/GeekDiskView.swift")
        XCTAssertTrue(disk.contains("GeekIStatRowsCard(title: L10n.text(\"网络磁盘\", \"Network Disks\")"))
        XCTAssertTrue(disk.contains(".accessibilityLabel(L10n.text(\"网络磁盘\", \"Network Disks\"))"))
        XCTAssertFalse(disk.contains("L10n.text(\"网络硬盘"))
        XCTAssertTrue(disk.contains(
            "title: mode == .read ? L10n.text(\"读\", \"Read\") : L10n.text(\"写\", \"Write\"),"))

        let sensors = try Self.source("Views/MenuBarAdvanced/GeekSensorsView.swift")
        let helper = try Self.source("Views/MenuBarAdvanced/GeekHelperPowerMetricsCards.swift")
        XCTAssertTrue(sensors.contains("geekSensorReadoutCard(L10n.text(\"环境光\", \"LIGHT\"), rows: [readout])"))
        XCTAssertTrue(helper.contains("geekSensorReadoutCard(L10n.text(\"电流\", \"AMPERAGE\"), rows: current)"))
        XCTAssertFalse((sensors + helper).contains("L10n.text(\"环境光\", \"AMBIENT LIGHT\")"))
        XCTAssertFalse((sensors + helper).contains("L10n.text(\"电流\", \"CURRENT\")"))

        let power = try Self.source("Views/MenuBarAdvanced/GeekPowerView.swift")
        XCTAssertTrue(power.contains("title: L10n.text(\"使用大量能耗\", \"Using Significant Energy\"),"))
        XCTAssertFalse(power.contains("L10n.text(\"使用显著能耗\""))
    }

    /// The level-three history titles (each history section's
    /// `drawSectionLabel`) and tooltip rows (`itemForIndex:`): network
    /// 'Network.Network', pressure 'Memory.Pressure', swap 'Memory.Swap',
    /// disk 'Disks.Disk Activity'; the GPU's row 'GPU.Processor', the
    /// sensors' and the fans' 'Sensors.Value', the disk's 'Disks.Read' and
    /// 'Disks.Write'.
    func testHistoryTitlesAndTooltipRowsUseIStatsLabels() throws {
        let detail = try Self.source("Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        XCTAssertTrue(try Self.body(of: "struct GeekNetworkHistoryHoverDetail: View {", in: detail)
            .contains("title: L10n.text(\"网络\", \"Network\"),"))
        XCTAssertFalse(detail.contains("L10n.text(\"网络活动\", \"Network Activity\")"))

        let pressure = try Self.body(of: "struct GeekMemoryHistoryHoverDetail: View {", in: detail)
        XCTAssertEqual(Self.count("title: L10n.text(\"压力\", \"Pressure\"),", in: pressure), 2,
                       "the title and the tooltip row")
        XCTAssertFalse(detail.contains("L10n.text(\"内存压力\", \"Memory Pressure\")"))
        XCTAssertFalse(detail.contains("L10n.text(\"压力评估\""))

        let swap = try Self.body(of: "struct GeekSwapHoverDetail: View {", in: detail)
        XCTAssertEqual(Self.count("title: L10n.text(\"已使用的交换\", \"Swap\"),", in: swap), 2,
                       "the title and the tooltip row")
        XCTAssertFalse(swap.contains("L10n.text(\"已用\", \"Used\")"))
        XCTAssertFalse(swap.contains("L10n.text(\"交换内存\", \"Swap Memory\")"))

        XCTAssertTrue(try Self.body(of: "struct GeekDiskIOHoverDetail: View {", in: detail)
            .contains("title: L10n.text(\"硬盘活动\", \"Disk Activity\"),"))
        XCTAssertFalse(detail.contains("L10n.text(\"磁盘 I/O\", \"Disk I/O\")"))

        let gpu = try Self.body(of: "struct GeekGPUHoverDetail: View {", in: detail)
        XCTAssertTrue(gpu.contains("title: L10n.text(\"处理器\", \"Processor\"),"))
        XCTAssertFalse(gpu.contains("title: \"GPU\","))

        let details = try Self.source("Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        XCTAssertTrue(try Self.body(of: "struct GeekSensorMetricHoverDetail: View {", in: details)
            .contains("title: L10n.text(\"数值\", \"Value\"),"))
        XCTAssertTrue(try Self.body(of: "struct GeekFanHoverDetail: View {", in: details)
            .contains("series: Self.chartSeries(selectedFanIndex: selectedFanIndex, title: L10n.text(\"数值\", \"Value\"),"))

        let charts = try Self.source("Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        let diskChart = try Self.body(of: "struct GeekDiskIOChart: View {", in: charts)
        XCTAssertEqual(Self.count("title: L10n.text(\"读\", \"Read\")", in: diskChart), 2, "the legend and the tooltip row")
        XCTAssertEqual(Self.count("title: L10n.text(\"写\", \"Write\")", in: diskChart), 2, "the legend and the tooltip row")
        XCTAssertFalse(diskChart.contains("L10n.text(\"读取\", \"Read\")"))
        XCTAssertFalse(diskChart.contains("L10n.text(\"写入\", \"Write\")"))
    }

    /// The uptime page's three groups (B9): 'CPU.Powered On', 'CPU.Awake'
    /// and 'CPU.Sleeping', drawn upper case; 'CPU.Uptime' names the page for
    /// VoiceOver. The page stays 170 × 130 in both languages (D137).
    func testUptimePageUsesIStatsLabels() throws {
        eachLanguage { chinese in
            let page = GeekProcessorUptimeHoverDetail(poweredOnAt: "10/19 08:00", awake: "3:12", asleep: "0:48")
            XCTAssertEqual(page.groups.map(\.title),
                           chinese ? ["开机", "活跃", "正在睡眠"] : ["Powered On", "Awake", "Sleeping"])
            XCTAssertEqual(page.popoverSize, CGSize(width: 170, height: 130))
        }
        let uptime = try Self.body(of: "struct GeekProcessorUptimeHoverDetail: View {",
                                   in: try Self.source("Views/MenuBarAdvanced/GeekHoverDetailTarget.swift"))
        XCTAssertTrue(uptime.contains(".accessibilityLabel(L10n.text(\"电脑开启时间\", \"Uptime\"))"))
    }

    /// `-[BBRBatteryMenuEnergyModeSection drawRect:]`: 'Power.Energy Mode' in
    /// upper case, or 'Power.Mode' when that title (the label font), the
    /// value (the value font), 16 and 20 are wider than the section; both
    /// unrounded. The value is iStat's 'Power.Automatic', 'Power.Low Power'
    /// or 'Power.High Power', then our charge limit.
    func testEnergyModeTitleGivesWayToModeLikeIStat() throws {
        XCTAssertEqual(GeekEnergyModeTitle.padding, 36)
        XCTAssertEqual(GeekEnergyModeTitle.sectionWidth, 224, "the power page's 240 less 2 × 8")
        let titleFont = NSFont.systemFont(ofSize: 12)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        try eachLanguage { chinese in
            let full = chinese ? "能耗模式" : "Energy Mode"
            let short = chinese ? "模式" : "Mode"
            XCTAssertEqual(BatteryChargeLimitPresentation.energyModeCardTitle(
                mode: .automatic, state: nil, usesChinese: chinese), chinese ? "自动" : "Automatic")
            for value in try Self.energyModeValues(chinese: chinese) {
                let needed = width(full.uppercased(), titleFont) + width(value, valueFont) + 36
                let title = GeekEnergyModeTitle.title(value: value)
                XCTAssertEqual(title, needed > 224 ? short : full, value)
                // The boundary: as wide as the section still fits.
                XCTAssertEqual(GeekEnergyModeTitle.title(value: value, sectionWidth: needed), full, value)
                XCTAssertEqual(GeekEnergyModeTitle.title(value: value, sectionWidth: needed - 0.01), short, value)
                // The header row (8 pt insets, 6 pt spacing either side of the
                // spacer) shows the value whole beside the chosen title.
                let row = width(title.uppercased(), titleFont) + 3 * MiniWindowStyleTokens.inlineSpacing
                    + width(value, valueFont)
                XCTAssertLessThanOrEqual(row, 224 - 2 * GeekIStatCardGeometry.inset, "\(title): \(value)")
                XCTAssertLessThanOrEqual(width(value, valueFont), GeekIStatCardGeometry.titleTrailingMaximumWidth, value)
            }
        }
        // Chinese keeps 能耗模式 for every value; English keeps ENERGY MODE for
        // the plain mode and gives way to MODE once the limit follows.
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(Set(try Self.energyModeValues(chinese: true).map { GeekEnergyModeTitle.title(value: $0) }), ["能耗模式"])
        chinese.restore()
        let english = MiniWindowLogicLanguageScope(.english)
        defer { english.restore() }
        XCTAssertEqual(GeekEnergyModeTitle.title(value: "Automatic"), "Energy Mode")
        XCTAssertEqual(GeekEnergyModeTitle.title(value: "High Power"), "Energy Mode")
        XCTAssertEqual(GeekEnergyModeTitle.title(value: "Low Power · Limit 80%"), "Mode")
        XCTAssertEqual(GeekEnergyModeTitle.title(value: "Automatic · Full this time"), "Mode")
    }

    /// The energy-mode card takes the title from the value it shows.
    func testEnergyModeCardUsesTheFallbackTitle() throws {
        let power = try Self.source("Views/MenuBarAdvanced/GeekPowerView.swift")
        let card = try MiniWindowLogicFixtures.section(
            power, from: "private var geekPowerModeCard: some View {", to: "func changeEnergyMode(")
        XCTAssertTrue(card.contains("let value = geekPowerModeTitle ?? geekHealthSamplingText"))
        XCTAssertTrue(card.contains("GeekIStatSingleRowCard(title: GeekEnergyModeTitle.title(value: value)) {"))
        XCTAssertTrue(card.contains("Text(value)"))
        XCTAssertFalse(power.contains("L10n.text(\"能耗模式\", \"ENERGY MODE\")"))
    }

    /// The card as the power page draws it, at the section's width, in both
    /// languages and both looks; exported for review when asked
    /// (`STORAGE_CLEANER_ISTAT_LAYOUT_EVIDENCE`).
    func testEnergyModeCardRendersTheChosenTitle() throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let values = language == .zhHans ? ["自动", "低能耗 · 上限 80%", "自动 · 本次充满"]
                                            : ["Automatic", "Low Power · Limit 80%", "Automatic · Full this time"]
            for (index, value) in values.enumerated() {
                let card = GeekIStatSingleRowCard(title: GeekEnergyModeTitle.title(value: value)) {
                    Text(value)
                        .geekIStatValueText()
                }
                for (mode, look) in [(MiniWindowVisualMode.black, "night"), (.graphite, "day")] {
                    let bitmap = try Self.render(card, width: GeekEnergyModeTitle.sectionWidth, mode: mode)
                    XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 224 + 2 * GeekPanelLayout.contentPadding, accuracy: 0.5)
                    XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2,
                                   GeekIStatSectionGeometry.singleRowHeight + 2 * GeekPanelLayout.contentPadding,
                                   accuracy: 0.5)
                    try Self.export(bitmap, name: "energy-mode-\(language == .zhHans ? "zh" : "en")-\(index)-\(look)")
                }
            }
        }
    }

    // MARK: - Helpers

    private static func render<Content: View>(_ card: Content, width: CGFloat,
                                              mode: MiniWindowVisualMode) throws -> NSBitmapImageRep {
        let content = card
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(GeekPanelLayout.contentPadding)
            .metricPanelShell()
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: mode))
            .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private static func export(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_ISTAT_LAYOUT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// Every value the energy-mode card can show: the three modes, or none,
    /// with each charge-limit state the presentation tells apart.
    private static func energyModeValues(chinese: Bool) throws -> [String] {
        func state(_ source: BatteryChargeLimitSource, _ effective: Int?, temporary: Bool = false,
                   manualTemporary: Bool = false) -> BatteryChargeLimitState {
            BatteryChargeLimitState(target: .full, availableTargets: [.protected, .full],
                                    effectiveLimit: effective, source: source,
                                    smartChargingTemporarilyDisabled: temporary,
                                    manualLimitTemporarilyDisabled: manualTemporary)
        }
        let states: [BatteryChargeLimitState?] = [
            nil, state(.manual, 70), state(.manual, 80), state(.manualAndOptimized, 80), state(.unknown, 85),
            state(.manual, 90), state(.optimized, 95), state(.none, 100), state(.none, 100, temporary: true),
            state(.manual, 100, manualTemporary: true),
        ]
        var values: [String] = []
        for mode: BatteryPowerMode? in [.automatic, .lowPower, .highPower, nil] {
            for value in states {
                if let text = BatteryChargeLimitPresentation.energyModeCardTitle(mode: mode, state: value,
                                                                                 usesChinese: chinese) {
                    values.append(text)
                }
            }
        }
        XCTAssertGreaterThan(values.count, 30)
        return values
    }

    private func eachLanguage(_ body: (_ chinese: Bool) throws -> Void) rethrows {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            try body(language == .zhHans)
        }
    }

    private static func count(_ text: String, in source: String) -> Int {
        source.components(separatedBy: text).count - 1
    }

    /// A type's source: from its declaration to the next top-level one.
    private static func body(of declaration: String, in source: String,
                             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration), "missing \(declaration)", file: file, line: line)
        let rest = source[start.upperBound...]
        let end = ["\nstruct ", "\nenum ", "\nextension ", "\nprivate struct ", "\nfinal class ", "\n#if "]
            .compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
        return String(rest[..<end])
    }

    private static func source(_ path: String) throws -> String {
        try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/\(path)")
    }
}
#endif
