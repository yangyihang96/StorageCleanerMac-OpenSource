import Foundation
import XCTest
@testable import StorageCleanerMac

/// Temporarily switches the app language through the argument domain.
/// Lives outside `#if DEBUG` because Release test builds use it too
/// (health event and protection audit tests).
@MainActor
final class CalibrationLanguageScope {
    private let original: [String: Any]
    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(L10n.appLanguage, language)
    }
    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}
