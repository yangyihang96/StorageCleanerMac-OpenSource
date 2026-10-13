#if DEBUG
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MSeriesV11TerminationPresentationTests: XCTestCase {
    private func result(failure: BenchmarkV7Failure) -> BenchmarkV7Result {
        let base = MSeriesV11PageFixture.result(variant: "partial")
        return .init(recordID: base.recordID, mSeries: base.mSeries, mSeriesV11: base.mSeriesV11,
            session: base.session, preflight: base.preflight, versions: base.versions,
            metrics: [], coreScore: nil, completedAt: base.completedAt, failure: failure)
    }
    func testKnownStopCodesHaveChineseAndEnglishTextWithoutInternalStrings() throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        let translations = [
            "thermalProtection": ("温度过高 · 测试已停止以保护设备", "High temperature · Test stopped to protect the device"),
            "timeout": ("测试超时 · 保留已完成测量", "Test timed out · Completed measurements retained"),
            "warmupTimeout": ("预热超时 · 测试已停止", "Warm-up timed out · Test stopped"),
            "clockInvalid": ("计时证据无效 · 测试已停止", "Invalid timing evidence · Test stopped"),
            "invalidBatch": ("测量证据无效 · 测试已停止", "Invalid measurement evidence · Test stopped"),
            "metadataBudget": ("测量记录超出写入预算 · 测试已停止", "Measurement record exceeded the write budget · Test stopped"),
            "evidenceBudgetForecast": ("预计测量记录超出写入预算 · 测试已停止", "Expected measurement record exceeds the write budget · Test stopped"),
            "coreIncomplete": ("测量未全部完成 · 保留已完成测量", "Measurements incomplete · Completed measurements retained"),
            "partial-v11-result": ("测量未全部完成 · 保留已完成测量", "Measurements incomplete · Completed measurements retained"),
            "native-arm64-required": ("需要原生 Apple 芯片环境 · 测试已停止", "Native Apple silicon environment required · Test stopped")
        ]
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            for (code, text) in translations {
                for failure in [BenchmarkV7Failure.validationFailed(code), .invalidMeasurement(code)] {
                    let disposition = MSeriesV11PagePresentation.ResultDisposition(result: result(failure: failure), history: [])
                    XCTAssertEqual(disposition.terminationText, language == .zhHans ? text.0 : text.1)
                    XCTAssertFalse(disposition.terminationText?.contains(code) == true)
                }
            }
            let context = BenchmarkV7TimeoutContext(phase: .running, category: .cpu, workloadID: "private-workload-code")
            let timedOut = MSeriesV11PagePresentation.ResultDisposition(result: result(failure: .timedOut(context)), history: [])
            XCTAssertEqual(timedOut.terminationText, L10n.text("测试超时 · 保留已完成测量", "Test timed out · Completed measurements retained"))
            let restart = MSeriesV11PagePresentation.ResultDisposition(result: result(failure: .restartRequired(context)), history: [])
            XCTAssertEqual(restart.terminationText, L10n.text("任务未确认停止 · 需重启应用", "Termination unconfirmed · Restart required"))
            for text in [timedOut.terminationText, restart.terminationText] {
                XCTAssertFalse(text?.contains("phase=") == true)
                XCTAssertFalse(text?.contains("private-workload-code") == true)
            }
            let unknown = MSeriesV11PagePresentation.ResultDisposition(result: result(failure: .validationFailed("internal-not-for-ui")), history: [])
            XCTAssertEqual(unknown.terminationText, L10n.text("测量未通过校验 · 测试已停止", "Measurement validation failed · Test stopped"))
        }
    }
    func testFailedSaveStateIsScopedToExactResultAndDoesNotReplaceStopReason() {
        let stopped = result(failure: .cancelled)
        let another = result(failure: .validationFailed("thermalProtection"))
        let failed = MSeriesV11SaveState(result: stopped, state: .failed)
        let original = MSeriesV11PagePresentation.ResultDisposition(result: stopped, history: [], saveState: failed)
        XCTAssertTrue(original.saveFailed)
        XCTAssertEqual(original.failure, .cancelled)
        XCTAssertNotNil(original.terminationText)
        XCTAssertNotNil(original.saveFailureText)
        let openedHistory = MSeriesV11PagePresentation.ResultDisposition(result: another, history: [another], saveState: failed)
        XCTAssertFalse(openedHistory.saveFailed)
        XCTAssertTrue(openedHistory.savedLocally)
        XCTAssertEqual(openedHistory.failure, .validationFailed("thermalProtection"))
        XCTAssertNil(openedHistory.saveFailureText)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try? String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkWorkspaceView.swift"), encoding: .utf8)
        XCTAssertTrue(workspace?.contains("saveState: benchmarkStore.v11SaveState") == true)
        let page = try? String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11ResultPage.swift"), encoding: .utf8)
        XCTAssertTrue(page?.contains("saveState: saveState") == true)
        XCTAssertTrue(page?.contains("if let storage = disposition.saveFailureText") == true)
        XCTAssertTrue(page?.contains("if let termination = disposition.terminationText") == true)
    }
}
#endif
