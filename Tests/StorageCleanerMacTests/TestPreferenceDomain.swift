import Foundation
import XCTest

/// D48：测试偏好只使用临时目录内的绝对路径域。跨 actor 只传域名，
/// 在使用线程重新打开 defaults，不把 UserDefaults 声称为 Sendable。
enum TestPreferenceDomain {
    static func make(
        file: StaticString = #filePath
    ) -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = makeSuite(file: file)
        guard let defaults = open(suiteName: suiteName) else {
            preconditionFailure("无法创建临时测试偏好域")
        }
        return (defaults, suiteName)
    }

    /// 唯一目录由调用方通过 cleanup 删除；适合已有 tearDown／defer 的夹具。
    static func makeSuite(file: StaticString = #filePath) -> String {
        let owner = URL(fileURLWithPath: String(describing: file)).deletingPathExtension().lastPathComponent
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StorageCleanerMac-TestPreferences-\(owner)-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("无法创建临时测试偏好目录：\(error)")
        }
        return directory.appendingPathComponent("defaults", isDirectory: false).path
    }

    /// 自动登记清理。闭包只捕获 Sendable 的 String，可用于普通及 @MainActor 测试。
    static func make(for testCase: XCTestCase, file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let fixture = make(file: file)
        let suiteName = fixture.suiteName
        testCase.addTeardownBlock {
            cleanup(suiteName: suiteName, file: file, line: line)
        }
        return fixture.defaults
    }

    /// 重新打开已创建的临时域，也用于验证 Sparkle 提供的绝对路径域。
    /// 先检查词法路径及符号链接解析后的路径，拒绝普通域名及临时目录外的路径。
    static func open(suiteName: String) -> UserDefaults? {
        precondition(isIsolatedSuiteName(suiteName), "测试偏好域必须是不会落进真实偏好目录的绝对路径：\(suiteName)")
        return UserDefaults(suiteName: suiteName)
    }

    /// 偏好只接受临时目录中的绝对路径，不再允许个人 home 中的夹具例外。
    static func isIsolatedSuiteName(_ suiteName: String) -> Bool {
        isTemporarySuiteName(suiteName)
    }

    static func isTemporarySuiteName(_ suiteName: String) -> Bool {
        guard (suiteName as NSString).isAbsolutePath else { return false }
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let root = temporaryRoot.resolvingSymlinksInPath()
        let lexicalSuite = URL(fileURLWithPath: suiteName).standardizedFileURL
        let suite = lexicalSuite.resolvingSymlinksInPath()
        let isLexicallyTemporary = lexicalSuite.path.hasPrefix(temporaryRoot.path + "/")
            || lexicalSuite.path.hasPrefix(root.path + "/")
        return isLexicallyTemporary && suite.path.hasPrefix(root.path + "/")
            && suite.deletingLastPathComponent().path != root.path
    }

    /// 清空持久域并同步后，删除本工厂拥有的整个目录，包括 defaults.plist。
    /// 可重复调用；不删除任何外部夹具目录或用户偏好目录。
    static func cleanup(suiteName: String, file: StaticString = #filePath, line: UInt = #line) {
        guard isTemporarySuiteName(suiteName) else {
            XCTFail("拒绝清理临时目录外的偏好域", file: file, line: line)
            return
        }
        let suite = URL(fileURLWithPath: suiteName).standardizedFileURL
        let directory = suite.deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard suite.lastPathComponent == "defaults",
              directory.lastPathComponent.hasPrefix("StorageCleanerMac-TestPreferences-"),
              directory.deletingLastPathComponent().resolvingSymlinksInPath() == root else {
            XCTFail("拒绝删除非测试偏好工厂拥有的目录", file: file, line: line)
            return
        }
        let defaults = open(suiteName: suiteName)
        defaults?.removePersistentDomain(forName: suiteName)
        defaults?.synchronize()
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("临时测试偏好目录清理失败：\(error)", file: file, line: line)
            }
        }
    }
}

/// L10n／首次授权标记没有 defaults 注入点；沿用现有界面测试的 argumentDomain
/// 覆盖方式，仅改内存并发送缓存失效通知。作用域结束必须显式 restore。
final class TestVolatilePreferences {
    private let original: [String: Any]

    init() {
        original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    func set(_ value: Any, forKey key: String) {
        var values = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        values[key] = value
        apply(values)
    }

    func restore() {
        apply(original)
    }

    private func apply(_ values: [String: Any]) {
        UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}
