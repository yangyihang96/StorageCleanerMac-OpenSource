import FanControlShared
import XCTest
@testable import StorageCleanerMac

final class MacMiniModePresentationTests: XCTestCase {
    func testToggleTracksPersistedModeEvenOnBatteryOrFailedReadback() {
        XCTAssertFalse(MacMiniModePresentation.isOn(nil))
        XCTAssertFalse(MacMiniModePresentation.isOn(status(mode: .off, disabled: false)))
        XCTAssertTrue(MacMiniModePresentation.isOn(status(mode: .whenOnAC, source: .battery, disabled: false)))
        XCTAssertTrue(MacMiniModePresentation.isOn(status(mode: .whenOnAC, disabled: false, failure: .verificationFailed)))
    }

    func testConsistentACAndBatteryDoNotShowFalseMismatch() {
        XCTAssertNil(MacMiniModePresentation.reason(status(mode: .whenOnAC, disabled: true)))
        XCTAssertNil(MacMiniModePresentation.reason(status(mode: .whenOnAC, source: .battery, disabled: false)))
        XCTAssertNil(MacMiniModePresentation.reason(status(mode: .off, disabled: false)))
    }

    func testMismatchUnknownAndPendingRestoreRemainVisible() {
        XCTAssertNil(MacMiniModePresentation.reason(nil))
        for state in [status(mode: .whenOnAC, disabled: false),
                      status(mode: .whenOnAC, source: .battery, disabled: true),
                      status(mode: .whenOnAC, source: .unknown, disabled: true),
                      status(mode: .off, disabled: true, owned: true),
                      status(mode: .off, disabled: nil)] as [MacMiniModeStatus?] {
            XCTAssertNotNil(MacMiniModePresentation.reason(state))
        }
    }

    func testExternalSettingHasReasonWithoutBeingClaimedAsOurs() {
        let state = status(mode: .off, disabled: true)
        XCTAssertEqual(state.settingOwner, .externalOrUnknown)
        XCTAssertNotNil(MacMiniModePresentation.reason(state))
        XCTAssertTrue(state.isConsistent)
    }

    func testEveryFailureHasAUserVisibleReason() {
        for failure in [MacMiniModeFailure.stateUnavailable, .persistenceFailed, .commandFailed,
                        .verificationFailed, .sleepRequestFailed, .conflictingIdentity] {
            XCTAssertFalse(MacMiniModePresentation.failureMessage(failure).isEmpty)
            XCTAssertNotNil(MacMiniModePresentation.reason(status(mode: .whenOnAC, disabled: false, failure: failure)))
        }
    }

    func testChineseAndEnglishTitlesSafetyAndActualStateDetail() {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        let state = status(mode: .whenOnAC, disabled: true, owned: true)
        preferences.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(MacMiniModePresentation.title, "Mac mini 模式：插电时不睡眠（合盖也继续运行）")
        XCTAssertEqual(MacMiniModePresentation.safetyNotice, "拔电后自动恢复睡眠")
        XCTAssertTrue(MacMiniModePresentation.detail(state).contains("电源：插电"))
        XCTAssertTrue(MacMiniModePresentation.detail(state).contains("已合盖：未知"))
        XCTAssertTrue(MacMiniModePresentation.detail(state).contains("系统禁止睡眠：是"))
        XCTAssertTrue(MacMiniModePresentation.detail(state).contains("本应用助手负责恢复"))
        preferences.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(MacMiniModePresentation.title, "Mac mini mode: no sleep on AC (runs with lid closed)")
        XCTAssertEqual(MacMiniModePresentation.safetyNotice, "Unplugging automatically restores sleep")
        XCTAssertTrue(MacMiniModePresentation.detail(state).contains("Lid closed: Unknown"))
        XCTAssertTrue(MacMiniModePresentation.detail(state).contains("System sleep disabled: Yes"))
    }

    func testPersistenceDiagnosticExplainsLockPermissionsAndReloadInBothLanguages() {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            let message = MacMiniModePresentation.failureMessage(MacMiniModeFailure.persistenceFailed)
            XCTAssertTrue(message.contains(language == .zhHans ? "锁目录权限" : "lock directory permissions"))
            XCTAssertTrue(message.contains(language == .zhHans ? "重新加载助手" : "reload the helper"))
            XCTAssertEqual(MacMiniModePresentation.reason(status(mode: .off, disabled: false, owned: true,
                failure: .persistenceFailed)), message, "A successful emergency 0 does not hide a broken lock")
        }
    }

    private func status(
        mode: MacMiniMode, source: MacMiniPowerSource = .ac, disabled: Bool?, owned: Bool = false,
        failure: MacMiniModeFailure? = nil
    ) -> MacMiniModeStatus {
        MacMiniModeStatus(state: MacMiniPersistedState(mode: mode, ownsSleepDisabled: owned),
            readings: MacMiniSystemReadings(powerSource: source, sleepDisabled: disabled,
                                          clamshellClosed: nil, clamshellCausesSleep: nil), failure: failure)
    }
}
