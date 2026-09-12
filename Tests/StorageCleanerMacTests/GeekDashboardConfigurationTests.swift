import Foundation
import XCTest
@testable import StorageCleanerMac

final class GeekDashboardConfigurationTests: XCTestCase {
    func testDefaultConfigurationLimitsSummaryMetrics() {
        let configuration = GeekDashboardConfiguration.defaultValue

        XCTAssertEqual(configuration.summaryMetrics.count, 6)
        XCTAssertLessThanOrEqual(
            configuration.summaryMetrics.count,
            GeekDashboardConfiguration.maximumSummaryMetricCount
        )
        XCTAssertEqual(
            configuration.modules.filter(\.isVisible).map(\.module),
            [.processorGraphics, .coreMetrics, .disk, .network, .sensors, .power]
        )
        XCTAssertEqual(
            configuration.modules.map(\.module),
            GeekDashboardConfiguration.defaultModuleOrder
        )
        XCTAssertEqual(
            Set(configuration.modules.map(\.module)),
            Set(GeekDashboardModule.overviewCases)
        )
        XCTAssertFalse(configuration.modules.contains {
            !$0.module.isAvailableInOverview
        })
        XCTAssertTrue(configuration.modules.allSatisfy { $0.width == .full })
        XCTAssertEqual(configuration.chartRange, .oneHour)
        XCTAssertEqual(configuration.powerChartRange, .oneHour)
    }

    func testChartRangeOffersRequestedLongDurationsInOrder() {
        XCTAssertEqual(GeekChartRange.allCases, [
            .thirtySeconds,
            .oneMinute,
            .fiveMinutes,
            .tenMinutes,
            .fifteenMinutes,
            .oneHour,
            .threeHours,
            .sixHours,
            .twelveHours,
            .oneDay,
            .threeDays,
            .sevenDays,
            .fourteenDays,
            .twentyEightDays,
        ])
        XCTAssertEqual(GeekChartRange.allCases.map(\.duration), [
            30,
            60,
            300,
            600,
            900,
            3_600,
            10_800,
            21_600,
            43_200,
            86_400,
            259_200,
            604_800,
            1_209_600,
            2_419_200,
        ])
    }

    func testChartRangePickerLivesInHistoryHeaderAndPersistsSelection() throws {
        let hover = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift"
        )
        let panel = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
        )

        XCTAssertTrue(hover.contains("if showsRangePicker"))
        XCTAssertTrue(hover.contains("struct TimeRangeSelector"))
        XCTAssertTrue(hover.contains("ForEach(availableRanges)"))
        XCTAssertTrue(hover.contains("Image(systemName: \"chevron.up.chevron.down\")"))
        XCTAssertTrue(hover.contains(".menuIndicator(.hidden)"))
        XCTAssertFalse(hover.contains("Image(systemName: \"chevron.down\")"))
        XCTAssertTrue(hover.contains(".id(chartRangeSelection.range)"))
        XCTAssertTrue(hover.contains("TimeRangeSelector.rangeChangeAnimationDuration"))
        XCTAssertTrue(panel.contains("select: selectGeekChartRange"))
        XCTAssertTrue(panel.contains("selectedChartRangeMetric"))
        XCTAssertTrue(panel.contains("panelSettingsState.setGeekChartRange(range, for: metric)"))
        XCTAssertTrue(panel.contains("var historyReferenceDate: Date"))
        XCTAssertFalse(panel.contains("return MiniWindowDemoData.nativeDiskIOHistory"))
        XCTAssertTrue(panel.contains("var batteryPowerHistory"))
    }

    func testFastAndPowerRangesPersistIndependently() throws {
        var configuration = GeekDashboardConfiguration.defaultValue
        configuration.chartRange = .threeHours
        configuration.powerChartRange = .sixHours

        let restored = try JSONDecoder().decode(
            GeekDashboardConfiguration.self,
            from: JSONEncoder().encode(configuration)
        ).normalized()

        XCTAssertEqual(restored.chartRange, .threeHours)
        XCTAssertEqual(restored.powerChartRange, .sixHours)
    }

    func testNormalizedRepairsDuplicateAndDamagedConfiguration() {
        let configuration = GeekDashboardConfiguration(
            modules: [
                GeekDashboardModuleConfiguration(
                    module: .coreMetrics,
                    isVisible: false,
                    width: .half
                ),
                GeekDashboardModuleConfiguration(
                    module: .coreMetrics,
                    isVisible: true,
                    width: .full
                ),
                GeekDashboardModuleConfiguration(
                    module: .network,
                    isVisible: true,
                    width: .full
                ),
                GeekDashboardModuleConfiguration(
                    module: .fans,
                    isVisible: true,
                    width: .full
                ),
                GeekDashboardModuleConfiguration(
                    module: .systemLoad,
                    isVisible: true,
                    width: .full
                ),
                GeekDashboardModuleConfiguration(
                    module: .cleanupSummary,
                    isVisible: true,
                    width: .full
                ),
                GeekDashboardModuleConfiguration(
                    module: .memoryBreakdown,
                    isVisible: true,
                    width: .full
                ),
            ],
            summaryMetrics: [
                .cpu, .cpu, .gpu, .memory, .temperature, .fans, .battery, .disk,
            ],
            chartRange: .oneMinute
        )

        let normalized = configuration.normalized()

        XCTAssertEqual(normalized.modules.count, GeekDashboardModule.overviewCases.count)
        XCTAssertEqual(Set(normalized.modules.map(\.module)), Set(GeekDashboardModule.overviewCases))
        XCTAssertFalse(normalized.modules.contains {
            !$0.module.isAvailableInOverview
        })
        XCTAssertEqual(normalized.modules.first?.module, .coreMetrics)
        XCTAssertEqual(normalized.modules.first?.isVisible, false)
        XCTAssertEqual(normalized.modules.first?.width, .full)
        XCTAssertEqual(normalized.modules.dropFirst().first?.module, .network)
        XCTAssertEqual(normalized.modules.dropFirst().first?.width, .full)
        XCTAssertEqual(
            normalized.summaryMetrics,
            [.cpu, .gpu, .memory, .temperature, .fans, .battery]
        )
        XCTAssertEqual(normalized.chartRange, .oneMinute)
    }

    @MainActor
    func testShortHistorySelectionPersistsWithoutChangingSamplingFrequency() throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.defaults.set("twoSeconds", forKey: "menuBar.refreshInterval")
        let state = MenuBarPanelSettingsState(initialDensity: .geek, defaults: fixture.defaults)
        state.setGeekChartRange(.oneMinute, for: .cpu)
        state.setGeekChartRange(.fiveMinutes, for: GeekChartRangeMetric.memory)
        state.setGeekChartRange(.fifteenMinutes, for: .cpu)
        let restored = MenuBarPanelSettingsState(initialDensity: .geek, defaults: fixture.defaults)
        XCTAssertEqual(restored.geekChartRange(for: .cpu, fallbackTo: .processor), .fifteenMinutes)
        XCTAssertEqual(restored.geekChartRange(for: .memory, fallbackTo: .memory), .fiveMinutes)
        XCTAssertEqual(fixture.defaults.string(forKey: "menuBar.refreshInterval"), "twoSeconds")
    }

    func testStoredFallsBackToDefaultForCorruptPayload() throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.defaults.set(Data("not-json".utf8), forKey: GeekDashboardConfiguration.defaultsKey)

        XCTAssertEqual(
            GeekDashboardConfiguration.stored(in: fixture.defaults),
            .defaultValue
        )
    }

    func testModuleVisibilityAndWidthMutationsRespectModuleCapabilities() {
        var configuration = GeekDashboardConfiguration.defaultValue

        XCTAssertNil(configuration.modules.first { $0.module == .fans })
        configuration.setModule(.fans, isVisible: true)
        configuration.setModule(.systemLoad, isVisible: true)
        configuration.setModule(.cleanupSummary, isVisible: true)
        configuration.setModule(.memoryBreakdown, isVisible: true)
        configuration.setModule(.network, isVisible: false)
        configuration.setModule(.network, width: .full)
        configuration.setModule(.coreMetrics, width: .half)

        XCTAssertNil(configuration.modules.first { $0.module == .fans })
        XCTAssertNil(configuration.modules.first { $0.module == .systemLoad })
        XCTAssertNil(configuration.modules.first { $0.module == .cleanupSummary })
        XCTAssertNil(configuration.modules.first { $0.module == .memoryBreakdown })
        XCTAssertFalse(configuration.modules.first { $0.module == .network }?.isVisible ?? true)
        XCTAssertEqual(configuration.modules.first { $0.module == .network }?.width, .full)
        XCTAssertEqual(configuration.modules.first { $0.module == .coreMetrics }?.width, .full)
    }

    func testMoveModuleSupportsUpDownAndBoundaryClamping() {
        var configuration = GeekDashboardConfiguration.defaultValue

        configuration.moveModule(.processorGraphics, by: -1)
        XCTAssertEqual(configuration.modules.prefix(2).map(\.module), [.processorGraphics, .coreMetrics])

        configuration.moveModule(.processorGraphics, by: 2)
        XCTAssertEqual(configuration.modules[2].module, .processorGraphics)

        configuration.moveModule(.power, by: -2)
        XCTAssertEqual(configuration.modules[3].module, .power)

        configuration.moveModule(.power, by: 100)
        XCTAssertEqual(configuration.modules.last?.module, .power)

        let supportedOrder = configuration.modules.map(\.module)
        configuration.moveModule(.memoryBreakdown, by: -2)
        configuration.moveModule(.cleanupSummary, by: -2)
        XCTAssertEqual(configuration.modules.map(\.module), supportedOrder)
    }

    func testDragReorderMovesModuleBeforeDropTarget() {
        var configuration = GeekDashboardConfiguration.defaultValue

        configuration.moveModule(.network, before: .coreMetrics)
        XCTAssertEqual(configuration.modules.prefix(3).map(\.module), [
            .processorGraphics,
            .network,
            .coreMetrics
        ])

        configuration.moveModule(.network, before: .network)
        XCTAssertEqual(configuration.modules.dropFirst().first?.module, .network)
    }

    func testStoredLegacyDefaultMigratesToCompactCombinedLayout() throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let legacy = GeekDashboardConfiguration(
            modules: GeekDashboardModule.allCases.map { module in
                GeekDashboardModuleConfiguration(
                    module: module,
                    isVisible: module != .fans,
                    width: module == .coreMetrics ? .full : .half
                )
            },
            summaryMetrics: [.cpu, .gpu, .memory, .temperature, .fans, .battery],
            chartRange: .twoMinutes
        )
        fixture.defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: GeekDashboardConfiguration.defaultsKey
        )

        XCTAssertEqual(
            GeekDashboardConfiguration.stored(in: fixture.defaults),
            .defaultValue
        )
    }

    func testRemovedOverviewModuleCasesRemainCodableForLegacyPayloads() throws {
        for module in [
            GeekDashboardModule.fans,
            .systemLoad,
            .cleanupSummary,
            .memoryBreakdown,
        ] {
            let data = try JSONEncoder().encode(module)
            XCTAssertEqual(
                try JSONDecoder().decode(GeekDashboardModule.self, from: data),
                module
            )
        }
    }

    func testSummaryMetricsNeverExceedSixOrDropBelowOne() throws {
        var configuration = GeekDashboardConfiguration.defaultValue

        configuration.setSummaryMetric(.disk, isVisible: true)
        XCTAssertEqual(
            configuration.summaryMetrics.count,
            GeekDashboardConfiguration.maximumSummaryMetricCount
        )
        XCTAssertFalse(configuration.summaryMetrics.contains(.disk))

        let metricsToRemove = Array(configuration.summaryMetrics.dropLast())
        for metric in metricsToRemove {
            configuration.setSummaryMetric(metric, isVisible: false)
        }
        XCTAssertEqual(configuration.summaryMetrics.count, 1)

        let lastMetric = try XCTUnwrap(configuration.summaryMetrics.first)
        configuration.setSummaryMetric(lastMetric, isVisible: false)
        XCTAssertEqual(configuration.summaryMetrics, [lastMetric])

        configuration.setSummaryMetric(.disk, isVisible: true)
        XCTAssertEqual(configuration.summaryMetrics.count, 2)
        XCTAssertTrue(configuration.summaryMetrics.contains(.disk))
    }

    func testLegacyRingPreferenceIsIgnoredWhenDecoded() throws {
        let data = try XCTUnwrap(
            """
            {
              "modules": [],
              "summaryMetrics": ["cpu"],
              "ringMetrics": ["cpu"],
              "chartRange": 120
            }
            """.data(using: .utf8)
        )

        let configuration = try JSONDecoder().decode(
            GeekDashboardConfiguration.self,
            from: data
        ).normalized()

        XCTAssertEqual(configuration.summaryMetrics, [.cpu])
        XCTAssertEqual(configuration.modules.count, GeekDashboardModule.overviewCases.count)
        XCTAssertEqual(configuration.chartRange, .oneHour)
    }

    @MainActor
    func testCustomizerCancelRestoresPreferencesAndDoneKeepsChanges() throws {
        let fixture = try makeDefaultsFixture()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        var initial = GeekDashboardConfiguration.defaultValue
        initial.chartRange = .oneDay
        initial.setModule(.disk, isVisible: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let originalData = try encoder.encode(initial)
        defaults.set(originalData, forKey: GeekDashboardConfiguration.defaultsKey)
        let state = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)

        state.presentGeekEditor()
        state.updateGeekDashboardConfiguration { $0.chartRange = .sixHours }
        XCTAssertEqual(state.geekDashboardConfiguration.chartRange, .sixHours)
        XCTAssertEqual(defaults.data(forKey: GeekDashboardConfiguration.defaultsKey), originalData)
        state.resetGeekDashboardConfiguration()
        XCTAssertEqual(state.geekDashboardConfiguration, .defaultValue)
        XCTAssertEqual(defaults.data(forKey: GeekDashboardConfiguration.defaultsKey), originalData)
        state.presentGeekEditor()
        state.cancelGeekEditor()
        XCTAssertEqual(state.geekDashboardConfiguration, initial)
        XCTAssertEqual(GeekDashboardConfiguration.stored(in: defaults), initial)
        XCTAssertEqual(defaults.data(forKey: GeekDashboardConfiguration.defaultsKey), originalData)
        XCTAssertFalse(state.isGeekEditorPresented)

        state.presentGeekEditor()
        state.updateGeekDashboardConfiguration { $0.chartRange = .sixHours }
        XCTAssertEqual(defaults.data(forKey: GeekDashboardConfiguration.defaultsKey), originalData)
        state.dismissGeekEditor()
        let committedData = try XCTUnwrap(defaults.data(forKey: GeekDashboardConfiguration.defaultsKey))
        XCTAssertNotEqual(committedData, originalData)
        let committedConfiguration = state.geekDashboardConfiguration
        // SwiftUI may send its popover binding false after Done already closed it.
        state.cancelGeekEditor()
        state.dismissGeekEditor()
        XCTAssertEqual(state.geekDashboardConfiguration, committedConfiguration)
        XCTAssertEqual(defaults.data(forKey: GeekDashboardConfiguration.defaultsKey), committedData)
        XCTAssertEqual(GeekDashboardConfiguration.stored(in: defaults), committedConfiguration)
        XCTAssertFalse(state.isGeekEditorPresented)
    }

    @MainActor
    func testCustomizerCancelDoesNotCreatePreviouslyAbsentDefaults() throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let state = MenuBarPanelSettingsState(
            initialDensity: .geek,
            isGeekEditorPresented: true,
            defaults: fixture.defaults
        )
        XCTAssertNil(fixture.defaults.data(forKey: GeekDashboardConfiguration.defaultsKey))
        state.updateGeekDashboardConfiguration { $0.setModule(.disk, isVisible: false) }
        XCTAssertNil(fixture.defaults.data(forKey: GeekDashboardConfiguration.defaultsKey))
        state.resetGeekDashboardConfiguration()
        XCTAssertNil(fixture.defaults.data(forKey: GeekDashboardConfiguration.defaultsKey))
        state.cancelGeekEditor()
        state.cancelGeekEditor()
        XCTAssertEqual(state.geekDashboardConfiguration, .defaultValue)
        XCTAssertNil(fixture.defaults.object(forKey: GeekDashboardConfiguration.defaultsKey))
        XCTAssertFalse(state.isGeekEditorPresented)
    }

    @MainActor
    func testDashboardUpdatesOutsideEditorContinueToPersist() throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let state = MenuBarPanelSettingsState(initialDensity: .geek, defaults: fixture.defaults)
        state.updateGeekDashboardConfiguration { $0.chartRange = .sixHours }
        XCTAssertEqual(GeekDashboardConfiguration.stored(in: fixture.defaults).chartRange, .sixHours)
        state.resetGeekDashboardConfiguration()
        XCTAssertEqual(GeekDashboardConfiguration.stored(in: fixture.defaults), .defaultValue)
        XCTAssertNotNil(fixture.defaults.data(forKey: GeekDashboardConfiguration.defaultsKey))
        XCTAssertFalse(state.isGeekEditorPresented)
    }

    @MainActor
    func testMetricRangesPersistIndependentlyFromLegacyConfiguration() throws {
        let suiteName = "GeekDashboardConfigurationTests.Ranges.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        first.setGeekChartRange(.sixHours, for: PanelSection.processor)
        first.setGeekChartRange(.oneDay, for: PanelSection.network)
        first.setGeekChartRange(.sixHours, for: PanelSection.power)
        XCTAssertEqual(
            first.geekChartRange(for: .cpu, fallbackTo: .processor),
            .sixHours
        )

        first.setGeekChartRange(.threeHours, for: .cpu)
        first.setGeekChartRange(.oneDay, for: .gpu)
        first.setGeekChartRange(.twelveHours, for: .temperature)
        first.setGeekChartRange(.threeDays, for: .fan)
        first.setGeekChartRange(.sevenDays, for: .battery)
        first.setGeekChartRange(.fourteenDays, for: .energy)

        let reopened = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        XCTAssertEqual(reopened.geekChartRange(for: .processor), .sixHours)
        XCTAssertEqual(reopened.geekChartRange(for: .network), .oneDay)
        XCTAssertEqual(reopened.geekChartRange(for: .power), .sixHours)
        XCTAssertEqual(reopened.geekChartRange(for: .memory), .oneHour)
        XCTAssertEqual(reopened.geekChartRange(for: .cpu, fallbackTo: .processor), .threeHours)
        XCTAssertEqual(reopened.geekChartRange(for: .gpu, fallbackTo: .processor), .oneDay)
        XCTAssertEqual(reopened.geekChartRange(for: .temperature, fallbackTo: .sensors), .twelveHours)
        XCTAssertEqual(reopened.geekChartRange(for: .fan, fallbackTo: .sensors), .threeDays)
        XCTAssertEqual(reopened.geekChartRange(for: .battery, fallbackTo: .power), .sevenDays)
        XCTAssertEqual(reopened.geekChartRange(for: .energy, fallbackTo: .power), .fourteenDays)
    }

    func testLayoutPlannerBuildsFullAndHalfWidthRowsInOrder() {
        let configurations: [GeekDashboardModuleConfiguration] = [
            .init(module: .coreMetrics, isVisible: true, width: .full),
            .init(module: .network, isVisible: true, width: .half),
            .init(module: .memoryBreakdown, isVisible: true, width: .half),
            .init(module: .disk, isVisible: true, width: .full),
            .init(module: .sensors, isVisible: true, width: .half),
            .init(module: .fans, isVisible: true, width: .half),
            .init(module: .power, isVisible: true, width: .full),
            .init(module: .systemLoad, isVisible: true, width: .half),
            .init(module: .cleanupSummary, isVisible: true, width: .half),
        ]

        XCTAssertEqual(
            GeekDashboardLayoutPlanner.rows(for: configurations).map(\.modules),
            [
                [.coreMetrics],
                [.network],
                [.disk],
                [.sensors],
                [.power],
            ]
        )
    }

    func testCanvasPlannerKeepsFullWidthOrderAndBuildsIndependentColumns() {
        let configurations: [GeekDashboardModuleConfiguration] = [
            .init(module: .coreMetrics, isVisible: true, width: .full),
            .init(module: .systemLoad, isVisible: true, width: .half),
            .init(module: .processorGraphics, isVisible: true, width: .half),
            .init(module: .fans, isVisible: true, width: .half),
            .init(module: .network, isVisible: true, width: .half),
            .init(module: .memoryBreakdown, isVisible: true, width: .half),
            .init(module: .cleanupSummary, isVisible: true, width: .half),
            .init(module: .disk, isVisible: true, width: .half),
            .init(module: .sensors, isVisible: false, width: .half),
            .init(module: .power, isVisible: true, width: .full),
        ]

        let blocks = GeekDashboardCanvasPlanner.blocks(for: configurations)

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].fullWidthModule, .coreMetrics)
        XCTAssertEqual(blocks[1].orderedModules, [.processorGraphics, .network, .disk])
        XCTAssertEqual(blocks[1].primaryModules, [.processorGraphics, .disk])
        XCTAssertEqual(blocks[1].secondaryModules, [.network])
        XCTAssertEqual(blocks[2].fullWidthModule, .power)
    }

    func testUserDefaultsCodableRoundTripStoresNormalizedConfiguration() throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        var configuration = GeekDashboardConfiguration.defaultValue
        configuration.setModule(.disk, isVisible: false)
        configuration.setModule(.network, width: .full)
        configuration.moveModule(.network, by: -2)
        configuration.setSummaryMetric(.fans, isVisible: false)
        configuration.setSummaryMetric(.disk, isVisible: true)
        configuration.chartRange = .threeDays

        configuration.save(in: fixture.defaults)

        let data = try XCTUnwrap(
            fixture.defaults.data(forKey: GeekDashboardConfiguration.defaultsKey)
        )
        XCTAssertNoThrow(try JSONDecoder().decode(GeekDashboardConfiguration.self, from: data))
        XCTAssertEqual(
            GeekDashboardConfiguration.stored(in: fixture.defaults),
            configuration.normalized()
        )
    }

    private func source(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func makeDefaultsFixture() throws -> (
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "GeekDashboardConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
