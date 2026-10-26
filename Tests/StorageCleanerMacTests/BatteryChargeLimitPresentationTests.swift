import AppKit
import Foundation
import XCTest
@testable import StorageCleanerMac

final class BatteryChargeLimitPresentationTests: XCTestCase {
    func testEnergySummaryUsesEffectiveLimitAndSourceInBothLanguages() {
        let cases: [(BatteryChargeLimitState?, String, String)] = [
            (state(.optimized, effective: 80), "上限 80%（macOS 优化充电）", "Limit 80% (macOS optimized charging)"),
            (state(.manual, effective: 90), "上限 90%（手动）", "Limit 90% (manual)"),
            (state(.manualAndOptimized, effective: 80), "上限 80%（手动 + macOS 优化充电）", "Limit 80% (manual + macOS optimized charging)"),
            (state(.none, effective: 100), "不限", "No limit"),
            (state(.unknown, effective: 85), "上限 85%（来源未知）", "Limit 85% (source unknown)"),
            (state(.optimized, effective: nil), "上限未知（macOS 优化充电）", "Limit unknown (macOS optimized charging)"),
            (state(.manual, effective: nil), "上限未知（手动）", "Limit unknown (manual)"),
            (nil, "充电上限未知", "Charge limit unknown"),
        ]
        for (state, chinese, english) in cases {
            XCTAssertEqual(BatteryChargeLimitPresentation.summary(state, usesChinese: true), chinese)
            XCTAssertEqual(BatteryChargeLimitPresentation.summary(state, usesChinese: false), english)
        }
        // 夹具的手动目标为 100%，实际优化上限仍是 80%。
        XCTAssertEqual(state(.optimized, effective: 80).target, .full)
    }

    func testManual100MeansNoManualLimitAndOtherTargetsKeepTheirNumbers() {
        XCTAssertEqual(BatteryChargeLimitPresentation.manualTargetLabel(.full, usesChinese: true), "100%")
        XCTAssertEqual(BatteryChargeLimitPresentation.manualTargetLabel(.full, usesChinese: false), "100%")
        XCTAssertEqual(BatteryChargeLimitPresentation.manualTargetLabel(.protected, usesChinese: true), "80%")
        XCTAssertEqual(BatteryChargeLimitPresentation.manualTargetLabel(.protected, usesChinese: false), "80%")
    }

    func testOptimizedExplanationDistinguishesTemporaryAndPermanentControls() {
        let optimized = state(.optimized, effective: 80)
        XCTAssertEqual(
            BatteryChargeLimitPresentation.optimizedExplanation(optimized, usesChinese: true),
            "macOS 优化充电另设上限 80%；要这次充满请点“本次充到 100%”，要长期关闭请在系统设置里关闭优化充电。"
        )
        XCTAssertEqual(
            BatteryChargeLimitPresentation.optimizedExplanation(optimized, usesChinese: false),
            "macOS optimized charging sets a separate limit of 80%. For a full charge this time, click “Charge This Time to 100%”. To turn it off permanently, disable optimized charging in System Settings."
        )
        XCTAssertTrue(BatteryChargeLimitPresentation.optimizedExplanation(
            state(.optimized, effective: nil), usesChinese: true
        )?.contains("当前值未知") == true)
        XCTAssertTrue(BatteryChargeLimitPresentation.optimizedExplanation(
            state(.optimized, effective: nil), usesChinese: false
        )?.contains("current value unknown") == true)
        for source: BatteryChargeLimitSource in [.manual, .none, .unknown] {
            XCTAssertNil(BatteryChargeLimitPresentation.optimizedExplanation(state(source, effective: 100), usesChinese: true))
            XCTAssertNil(BatteryChargeLimitPresentation.optimizedExplanation(state(source, effective: 100), usesChinese: false))
        }
    }

    func testTemporaryStatusSurvivesReopeningFromReadOnlyState() {
        let temporary = state(.none, effective: 100, temporary: true)
        let optimized = state(.optimized, effective: 80)
        let cases: [(BatteryChargeLimitState, BatteryChargeLimitSource?)] = [
            (temporary, nil), (state(.none, effective: 100), .optimized),
        ]
        for (state, accepted) in cases {
            XCTAssertEqual(
                BatteryChargeLimitPresentation.fullChargeStatus(state, acceptedSource: accepted, usesChinese: true),
                "本次将充到 100%（优化充电已临时暂停）"
            )
            XCTAssertEqual(
                BatteryChargeLimitPresentation.fullChargeStatus(state, acceptedSource: accepted, usesChinese: false),
                "Charging to 100% this time (optimized charging temporarily paused)"
            )
        }
        XCTAssertEqual(BatteryChargeLimitPresentation.fullChargeStatus(
            state(.manual, effective: 100, manualTemporary: true), acceptedSource: .manual, usesChinese: true
        ), "本次将充到 100%（手动上限已临时解除）")
        XCTAssertEqual(BatteryChargeLimitPresentation.fullChargeStatus(
            state(.manual, effective: 100, manualTemporary: true), acceptedSource: .manual, usesChinese: false
        ), "Charging to 100% this time (manual limit temporarily lifted)")
        XCTAssertNil(BatteryChargeLimitPresentation.fullChargeStatus(optimized, usesChinese: true))
        XCTAssertNil(BatteryChargeLimitPresentation.fullChargeStatus(optimized, acceptedSource: .optimized, usesChinese: true))
    }

    func testUnsupportedMessageExplainsKnownAndUnknownSourcesInBothLanguages() {
        for source: BatteryChargeLimitSource in [.optimized, .manual, .manualAndOptimized, .none, .unknown] {
            let value = state(source, effective: 80)
            let chinese = BatteryChargeLimitPresentation.unsupportedMessage(value, usesChinese: true)
            let english = BatteryChargeLimitPresentation.unsupportedMessage(value, usesChinese: false)
            XCTAssertFalse(chinese.isEmpty)
            XCTAssertFalse(english.isEmpty)
            XCTAssertNotEqual(chinese, english)
            for internalName in ["MCL", "OBC", "PowerUI", "smartCharging", "temporarilyDisable", ".optimized"] {
                XCTAssertFalse(chinese.contains(internalName))
            }
        }
        XCTAssertTrue(BatteryChargeLimitPresentation.unsupportedMessage(nil, usesChinese: true).contains("未知"))
        XCTAssertTrue(BatteryChargeLimitPresentation.unsupportedMessage(nil, usesChinese: false).contains("unknown"))
    }

    func testUIUsesSharedSummaryAndPickerNeverRequestsTemporaryFullCharge() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let details = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"
        ), encoding: .utf8)
        let start = try XCTUnwrap(details.range(of: "private struct GeekChargeTargetSetting"))
        let updateStart = try XCTUnwrap(details.range(of: "    private func updateTarget", range: start.lowerBound..<details.endIndex))
        let requestStart = try XCTUnwrap(details.range(of: "    private func requestFullCharge", range: updateStart.lowerBound..<details.endIndex))
        let update = String(details[updateStart.lowerBound..<requestStart.lowerBound])
        XCTAssertTrue(update.contains("await setChargeTarget(target)"))
        XCTAssertFalse(update.contains("chargeToFull()"))
        XCTAssertTrue(details.contains("BatteryChargeLimitPresentation.manualTargetLabel(target)"))
        XCTAssertTrue(details.contains("BatteryChargeLimitPresentation.sourceCaption(chargeLimitState)"))
        XCTAssertTrue(details.contains("BatteryChargeLimitPresentation.fullChargeStatus("))
        // D124: the action is a row of the charge-limit text section, one
        // level shallower than the old group's stack.
        XCTAssertTrue(details.contains("if showsFullChargeAction && temporaryFullChargeStatus == nil {\n                fullChargeButton"))
        XCTAssertTrue(details.contains(".disabled(!canRequestFullCharge)"))
        XCTAssertTrue(details.contains("打开电池设置"))
        let power = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
        ), encoding: .utf8)
        XCTAssertTrue(power.contains("BatteryChargeLimitPresentation.energyModeCardTitle("))
        let titleStart = try XCTUnwrap(power.range(of: "private var geekPowerModeTitle:"))
        let titleEnd = try XCTUnwrap(power.range(of: "var geekBatteryPowerMode:", range: titleStart.lowerBound..<power.endIndex))
        let title = String(power[titleStart.lowerBound..<titleEnd.lowerBound])
        XCTAssertTrue(title.contains("mode: geekCurrentPowerMode, state: hasInternalBattery ? batteryChargeLimitState : nil"),
                      "卡片必须将当前能源模式与短摘要一起交给共享出口")
        XCTAssertFalse(title.contains("joined("))
        XCTAssertFalse(title.contains("values.append("))
        XCTAssertTrue(power.contains(".help(geekPowerModeHelpText)"))
        XCTAssertTrue(power.contains("geekPowerModeTitle ?? geekHealthSamplingText"), "悬停提示与卡片共用模式摘要")
        XCTAssertTrue(power.contains("chargeTargetPercent: batteryChargeLimitState?.effectiveLimit"))
        XCTAssertFalse(power.contains("batteryChargeLimitState?.target.displayText"))
        let palette = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift"
        ), encoding: .utf8)
        XCTAssertTrue(palette.contains("let result = await BatteryFullChargeService.requestToFull()\n                    auxiliaryState.refreshBatteryChargeLimitState(reason: .userOperation)"))
    }

    func testAcceptedSourceClearsWhenLimitReturnsSmartResumesOrReadFails() {
        let unlimited = state(.none, effective: 100)
        let paused = state(.none, effective: 100, temporary: true)
        for current: BatteryChargeLimitState? in [
            state(.optimized, effective: 80), state(.unknown, effective: 100), nil,
        ] {
            XCTAssertNil(BatteryChargeLimitPresentation.retainedAcceptedSource(
                .optimized, previous: unlimited, current: current, isRequesting: false))
        }
        // 即使两次回读上限同为 80%，也不能留着旧成功提示（R7）。
        let restored = state(.manual, effective: 80)
        XCTAssertNil(BatteryChargeLimitPresentation.retainedAcceptedSource(
            .manual, previous: restored, current: restored, isRequesting: false))
        XCTAssertNil(BatteryChargeLimitPresentation.retainedAcceptedSource(
            .optimized, previous: paused, current: unlimited, isRequesting: false))
        XCTAssertEqual(BatteryChargeLimitPresentation.retainedAcceptedSource(
            .optimized, previous: unlimited, current: unlimited, isRequesting: false), .optimized)
        XCTAssertEqual(BatteryChargeLimitPresentation.retainedAcceptedSource(
            .manual, previous: unlimited, current: nil, isRequesting: true), .manual)
    }

    func testManualTemporaryStatusComesFromReadOnlyStateWithoutViewMemory() throws {
        let manual = try XCTUnwrap(BatteryChargeLimitState.resolve(
            manualLimitEnabled: true, manualLimit: 80, availableLimits: [80, 100],
            effectiveLimit: 100, smartChargingRawValue: 1, maxLimited: false))
        XCTAssertTrue(manual.manualLimitTemporarilyDisabled)
        XCTAssertEqual(manual.source, .manual)
        XCTAssertEqual(BatteryChargeLimitPresentation.fullChargeStatus(manual, usesChinese: true),
                       "本次将充到 100%（手动上限已临时解除）")
        XCTAssertEqual(BatteryChargeLimitPresentation.fullChargeStatus(manual, usesChinese: false),
                       "Charging to 100% this time (manual limit temporarily lifted)")
        let restored = try XCTUnwrap(BatteryChargeLimitState.resolve(
            manualLimitEnabled: true, manualLimit: 80, availableLimits: [80, 100],
            effectiveLimit: 80, smartChargingRawValue: 1, maxLimited: true))
        XCTAssertFalse(restored.manualLimitTemporarilyDisabled)
        XCTAssertNil(BatteryChargeLimitPresentation.fullChargeStatus(restored))
    }

    func testOptimizedExplanationMatchesPowerAndButtonAvailability() throws {
        let optimized = state(.optimized, effective: 80)
        XCTAssertTrue(BatteryChargeLimitPresentation.optimizedExplanation(
            optimized, powerSource: .batteryPower, canRequestFullCharge: false, usesChinese: true
        )?.contains("接上电源后可以点“本次充到 100%”临时充满") == true)
        XCTAssertTrue(BatteryChargeLimitPresentation.optimizedExplanation(
            optimized, powerSource: .batteryPower, canRequestFullCharge: false, usesChinese: false
        )?.contains("Connect power, then click") == true)
        for language in [true, false] {
            let explanation = try XCTUnwrap(BatteryChargeLimitPresentation.optimizedExplanation(
                optimized, powerSource: .acPower, canRequestFullCharge: false, usesChinese: language))
            XCTAssertFalse(explanation.contains(language ? "请点" : "click"))
        }
        let unlimited = try XCTUnwrap(BatteryChargeLimitState.resolve(
            manualLimitEnabled: false, manualLimit: 80, availableLimits: [80, 100],
            effectiveLimit: 100, smartChargingRawValue: 1, maxLimited: false))
        XCTAssertEqual(BatteryChargeLimitPresentation.optimizedExplanation(unlimited, usesChinese: true),
                       "macOS 优化充电已开启，目前没有限制。")
        XCTAssertEqual(BatteryChargeLimitPresentation.optimizedExplanation(unlimited, usesChinese: false),
                       "macOS optimized charging is enabled; no limit is active now.")
        XCTAssertEqual(BatteryChargeLimitPresentation.noActiveLimitMessage(usesChinese: true), "当前没有生效的充电上限，无需解除。")
        XCTAssertEqual(BatteryChargeLimitPresentation.noActiveLimitMessage(usesChinese: false), "No charge limit is active; nothing to lift.")
    }

    func testShortCardSummaryHidesMissingStateAndFits264PointPageInBothLanguages() throws {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        func width(_ value: String) -> CGFloat {
            (value as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }
        for language in [true, false] {
            XCTAssertNil(BatteryChargeLimitPresentation.cardSummary(nil, usesChinese: language))
            XCTAssertNil(BatteryChargeLimitPresentation.cardSummary(state(.unknown, effective: nil), usesChinese: language))
            let room = CGFloat(264 - 2 * 8 - 2 * 8) - width(language ? "能源模式" : "ENERGY MODE") - 8
            for value in [state(.manual, effective: 70), state(.manual, effective: 80),
                          state(.manualAndOptimized, effective: 80), state(.unknown, effective: 85),
                          state(.manual, effective: 90), state(.optimized, effective: 95),
                          state(.none, effective: 100), state(.none, effective: 100, temporary: true),
                          state(.manual, effective: 100, manualTemporary: true)] {
                let text = try XCTUnwrap(BatteryChargeLimitPresentation.cardSummary(value, usesChinese: language))
                XCTAssertLessThanOrEqual(width(text), room, "264 pt: \(text)")
                print("能源卡片 \(language ? "中文" : "英文")：\(text) \(width(text)) / \(room) pt")
                XCTAssertFalse(text.contains("macOS"))
                XCTAssertFalse(text.contains(language ? "手动" : "manual"))
                for mode: BatteryPowerMode in [.automatic, .lowPower, .highPower] {
                    let title = try XCTUnwrap(BatteryChargeLimitPresentation.energyModeCardTitle(
                        mode: mode, state: value, usesChinese: language
                    ))
                    XCTAssertLessThanOrEqual(width(title), room, "264 pt 完整模式卡片: \(title)")
                    XCTAssertTrue(title.hasSuffix(" · " + text))
                    print("完整能源卡片 \(language ? "中文" : "英文")：\(title) \(width(title)) / \(room) pt")
                }
            }
            XCTAssertEqual(BatteryChargeLimitPresentation.cardSummary(state(.optimized, effective: 80), usesChinese: language),
                           language ? "上限 80%" : "Limit 80%")
            XCTAssertEqual(BatteryChargeLimitPresentation.cardSummary(state(.none, effective: 100), usesChinese: language),
                           language ? "无上限" : "No limit")
        }
    }

    func testEnergyModeCardKeepsCurrentModeWithShortLimitAndUnknownState() {
        for language in [true, false] {
            XCTAssertEqual(BatteryChargeLimitPresentation.energyModeCardTitle(
                mode: .automatic, state: state(.optimized, effective: 80), usesChinese: language
            // D138: iStat's 'Power.Automatic' (was "Auto · Limit 80%").
            ), language ? "自动 · 上限 80%" : "Automatic · Limit 80%")
            XCTAssertEqual(BatteryChargeLimitPresentation.energyModeCardTitle(
                mode: .lowPower, state: state(.manual, effective: 80), usesChinese: language
            // D124: iStat's and macOS's Chinese mode name (was 低功耗).
            ), language ? "低能耗 · 上限 80%" : "Low Power · Limit 80%")
            XCTAssertEqual(BatteryChargeLimitPresentation.energyModeCardTitle(
                mode: .automatic, state: state(.none, effective: 100), usesChinese: language
            // D138: was "Auto · No limit".
            ), language ? "自动 · 无上限" : "Automatic · No limit")
            XCTAssertEqual(BatteryChargeLimitPresentation.energyModeCardTitle(
                mode: .automatic, state: nil, usesChinese: language
            // D138: was "Auto".
            ), language ? "自动" : "Automatic", "读不到上限时仍保留已知能源模式")
            XCTAssertEqual(BatteryChargeLimitPresentation.energyModeCardTitle(
                mode: nil, state: state(.optimized, effective: 80), usesChinese: language
            ), language ? "上限 80%" : "Limit 80%", "未知能源模式不能编造自动")
            XCTAssertNil(BatteryChargeLimitPresentation.energyModeCardTitle(mode: nil, state: nil, usesChinese: language))
        }
    }

    func testTemporarySummariesDescribeThisChargeWithoutChangingManualTarget() {
        for value in [state(.none, effective: 100, temporary: true),
                      state(.manual, effective: 100, manualTemporary: true)] {
            for language in [true, false] {
                XCTAssertEqual(BatteryChargeLimitPresentation.cardSummary(value, usesChinese: language),
                               language ? "本次充满" : "Full this time")
                XCTAssertEqual(BatteryChargeLimitPresentation.energyModeCardTitle(
                    mode: .automatic, state: value, usesChinese: language),
                    // D138: iStat's 'Power.Automatic' (was "Auto · Full this time").
                    language ? "自动 · 本次充满" : "Automatic · Full this time")
                XCTAssertEqual(BatteryChargeLimitPresentation.summary(value, usesChinese: language),
                               language ? "本次充到 100%" : "Charging to 100% this time")
            }
        }
        let manual = BatteryChargeLimitState(target: .protected, availableTargets: [.protected, .full],
            effectiveLimit: 100, source: .manual, manualLimitTemporarilyDisabled: true)
        XCTAssertEqual(BatteryChargeLimitPresentation.summary(manual, usesChinese: true), "本次充到 100%")
        XCTAssertEqual(manual.target, .protected, "临时状态不得把所选手动目标改为 100%")
    }

    func testUnsupportedManualLimitReplacesOnlyPickerAndKeepsOtherControls() throws {
        XCTAssertEqual(BatteryChargeLimitPresentation.manualLimitUnavailableMessage(usesChinese: true), "本机不支持手动上限")
        XCTAssertEqual(BatteryChargeLimitPresentation.manualLimitUnavailableMessage(usesChinese: false), "Manual limit not supported on this Mac")
        let systemOnly = BatteryChargeLimitState(target: .full, availableTargets: [], effectiveLimit: 80, source: .optimized)
        XCTAssertEqual(BatteryChargeLimitPresentation.summary(systemOnly, usesChinese: true), "上限 80%（macOS 优化充电）")
        XCTAssertNotNil(BatteryChargeLimitPresentation.optimizedExplanation(systemOnly, usesChinese: false))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let details = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"), encoding: .utf8)
        let start = try XCTUnwrap(details.range(of: "private struct GeekChargeTargetSetting"))
        let guardStart = try XCTUnwrap(details.range(of: "if chargeLimitState?.availableTargets.isEmpty == false {",
                                                   range: start.lowerBound..<details.endIndex))
        // D149: the targets are one row of segments again (D124: tick rows).
        let picker = try XCTUnwrap(details.range(of: "chargeTargetSegments", range: guardStart.lowerBound..<details.endIndex))
        let explanation = try XCTUnwrap(details.range(of: "Text(BatteryChargeLimitPresentation.manualLimitUnavailableMessage())",
                                                    range: picker.lowerBound..<details.endIndex))
        let branchEnd = try XCTUnwrap(details.range(of: "if targetUpdateFailed {", range: explanation.lowerBound..<details.endIndex))
        XCTAssertLessThan(guardStart.lowerBound, picker.lowerBound)
        XCTAssertLessThan(picker.lowerBound, explanation.lowerBound)
        let remaining = String(details[branchEnd.lowerBound...])
        XCTAssertTrue(remaining.contains("BatteryChargeLimitPresentation.sourceCaption(chargeLimitState)"))
        XCTAssertTrue(remaining.contains("BatteryChargeLimitPresentation.fullChargeStatus("))
        XCTAssertTrue(remaining.contains("action: openBatterySettings"))
        XCTAssertTrue(remaining.contains("if showsFullChargeAction && temporaryFullChargeStatus == nil"))
    }

    func testSecondStepRejectionMessageUsesReadbackAndDoesNotInventMissingLimit() {
        for limit in [80, 85] {
            XCTAssertEqual(BatteryChargeLimitPresentation.optimizedChargingRejectedAfterManualLiftMessage(
                effectiveLimit: limit, usesChinese: true
            ), "已临时解除手动上限，但 macOS 拒绝暂停优化充电，充电仍限制在 \(limit)%。")
            XCTAssertEqual(BatteryChargeLimitPresentation.optimizedChargingRejectedAfterManualLiftMessage(
                effectiveLimit: limit, usesChinese: false
            ), "The manual limit was temporarily lifted, but macOS refused to pause optimized charging; charging is still limited to \(limit)%.")
        }
        for language in [true, false] {
            let missing = BatteryChargeLimitPresentation.optimizedChargingRejectedAfterManualLiftMessage(
                effectiveLimit: nil, usesChinese: language)
            XCTAssertTrue(missing.contains(language ? "未能回读确认" : "could not be verified"))
            XCTAssertFalse(missing.contains("80%"))
            let full = BatteryChargeLimitPresentation.optimizedChargingRejectedAfterManualLiftMessage(
                effectiveLimit: 100, usesChinese: language)
            XCTAssertTrue(full.contains(language ? "当前回读上限为 100%" : "reads back as 100%"))
            XCTAssertFalse(full.contains(language ? "仍限制在" : "still limited to"))
        }
    }

    func testPendingRequestKeepsExplanationAndOnlyDisablesActionWithoutAddingHeight() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let details = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"), encoding: .utf8)
        let start = try XCTUnwrap(details.range(of: "private struct GeekChargeTargetSetting"))
        let end = try XCTUnwrap(details.range(of: "enum GeekEnergyModePowerTitle", range: start.lowerBound..<details.endIndex))
        let setting = String(details[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(setting.contains("BatteryChargeLimitPresentation.sourceCaption(chargeLimitState)"))
        XCTAssertTrue(setting.contains("isFullChargeActionAvailable && !isRequesting"))
        let availabilityStart = try XCTUnwrap(setting.range(of: "private var isFullChargeActionAvailable:"))
        let availabilityEnd = try XCTUnwrap(setting.range(of: "private var targetStatusText:", range: availabilityStart.lowerBound..<setting.endIndex))
        XCTAssertFalse(setting[availabilityStart.lowerBound..<availabilityEnd.lowerBound].contains("isRequesting"))
        XCTAssertFalse(setting.contains("ProgressView()"), "请求进行中不能新增会改变自然高度的行")
        XCTAssertTrue(setting.contains(".disabled(!canRequestFullCharge)"))
        XCTAssertTrue(setting.contains("case .optimizedChargingRejectedAfterManualLift(let effectiveLimit):"))
        XCTAssertTrue(setting.contains("effectiveLimit: effectiveLimit"), "提示必须使用结果携带的拒绝后回读")
    }

    func testDemoFixturesDisableControlsAndFailureKeepsSeparateSummaryLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
        }
        let palette = try source("Views/MenuBarAdvanced/ControlPaletteViews.swift")
        XCTAssertTrue(palette.contains("chargeLimitControlsEnabled: allowsLiveChargeLimitControls"))
        XCTAssertTrue(palette.contains("guard allowsLiveChargeLimitControls else { return .unsupported }"))
        XCTAssertTrue(palette.contains("BatteryChargeLimitAccess.allowsLiveAccess && !fanControl.isDataOnlyFixture"))
        XCTAssertTrue(palette.contains("store.menuBarAuxiliaryMonitorState.setChargeLimitDataOnlyFixture(fanControl.isDataOnlyFixture)"))
        let fixture = try source("Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(fixture.contains("chargeLimitControlsEnabled: false"))
        let details = try source("Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        XCTAssertTrue(details.contains(".disabled(!controlsEnabled || isRequesting)"))
        XCTAssertTrue(details.contains("if chargeLimitState?.availableTargets.isEmpty == false {"))
        XCTAssertTrue(details.contains("guard controlsEnabled, availableTargets.contains(target), !isRequesting else { return }"))
        XCTAssertTrue(details.contains("guard canRequestFullCharge else { return }"))
        let failure = try XCTUnwrap(details.range(of: "if targetUpdateFailed {"))
        let summary = try XCTUnwrap(details.range(of: "BatteryChargeLimitPresentation.sourceCaption(chargeLimitState)"))
        XCTAssertLessThan(failure.lowerBound, summary.lowerBound)
        XCTAssertTrue(details.contains("acceptedSource = BatteryChargeLimitPresentation.retainedAcceptedSource("))
        let onChangeStart = try XCTUnwrap(details.range(of: ".onChange(of: chargeLimitState)"))
        let onChangeEnd = try XCTUnwrap(details.range(of: ".onChange(of: isRequesting)", range: onChangeStart.lowerBound..<details.endIndex))
        let onChange = String(details[onChangeStart.lowerBound..<onChangeEnd.lowerBound])
        XCTAssertTrue(onChange.contains("acceptedSource = BatteryChargeLimitPresentation.retainedAcceptedSource("),
                      "R7：系统状态变化必须实际接到清除函数")
    }

    private func state(
        _ source: BatteryChargeLimitSource, effective: Int?, temporary: Bool = false,
        manualTemporary: Bool = false
    ) -> BatteryChargeLimitState {
        BatteryChargeLimitState(
            target: .full, availableTargets: [.protected, .full],
            effectiveLimit: effective, source: source,
            smartChargingTemporarilyDisabled: temporary,
            manualLimitTemporarilyDisabled: manualTemporary
        )
    }
}
