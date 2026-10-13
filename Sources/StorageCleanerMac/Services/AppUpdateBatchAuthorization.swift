import AppKit
import Darwin
import FileOperationShared
import Foundation
import Security

protocol AppUpdateBatchAuthorizing: Sendable {
    func prepare(applications: [InstalledApplication], sessionID: UUID) async throws
    func upgrade(productID: UInt64) async throws
    func replace(candidate: URL, application: InstalledApplication) async throws
    func homebrewEnvironment() async throws -> [String: String]
    func homebrewExecutable() async throws -> AppUpdateExecutableIdentity?
    func revokeHomebrewAuthorization() async throws
    func finish() async
}
extension AppUpdateBatchAuthorizing {
    func homebrewEnvironment() async throws -> [String: String] { [:] }
    func homebrewExecutable() async throws -> AppUpdateExecutableIdentity? { nil }
    func revokeHomebrewAuthorization() async throws {}
}

protocol AppUpdateAskpassServing: Sendable {
    var environment: [String: String] { get }
    func finish()
}
private final class NativeUpdateAskpass: AppUpdateAskpassServing, @unchecked Sendable {
    let channel: UpdateAskpassChannel
    let executable: URL
    init(password: UpdatePasswordBuffer) throws {
        guard let executable = Bundle.main.url(forResource: "StorageCleanerUpdateAskpass", withExtension: nil),
              let application = UpdateAskpassCodeIdentity.file(Bundle.main.bundleURL),
              let bundled = UpdateAskpassCodeIdentity.file(executable), bundled.identifier == FileOperationIdentity.application + ".update-askpass" else {
            throw AuthorizedMoveError.unavailable
        }
        self.executable = executable
        let policy = UpdateAskpassPeerPolicy(executable: executable.path, application: application, bundledAskpass: bundled)
        channel = try UpdateAskpassChannel(password: password, authorizePeer: { policy.permits($0) })
    }
    var environment: [String: String] {
        ["SUDO_ASKPASS": executable.path, "STORAGE_CLEANER_ASKPASS_SOCKET": channel.socketPath,
            "STORAGE_CLEANER_ASKPASS_APP_PID": String(getpid()), "STORAGE_CLEANER_ASKPASS_APP_UID": String(getuid())]
    }
    func finish() { channel.finish() }
}

enum AppUpdateAuthorizationError: LocalizedError, Sendable {
    case declined, incorrectPassword, unavailable, helperUnavailable(String), sourceChanged(String)
    var errorDescription: String? {
        switch self {
        case .declined: L10n.text("已跳过：未授权", "Skipped: authorization declined")
        case .incorrectPassword: L10n.text("已跳过：管理员密码验证失败（最多三次）", "Skipped: administrator password verification failed (three attempts maximum)")
        case let .helperUnavailable(reason): L10n.text("已跳过：应用替换辅助程序不可用 · ", "Skipped: application replacement helper unavailable · ") + reason
        case .unavailable: L10n.text("已跳过：安全授权通道不可用", "Skipped: secure authorization channel unavailable")
        case let .sourceChanged(path): L10n.text("执行来源已改变或权限不可信（仅允许本机 admin 组写入），已拒绝：", "Execution source changed or permissions are untrusted (only local admin group write is permitted); rejected: ") + path
        }
    }
}

/// The approved terminal trust model applies only to this live batch. Nothing
/// in the privileged daemon executes mas/brew or handles this credential.
actor AppUpdateBatchAuthorization: AppUpdateBatchAuthorizing {
    typealias Prompt = @Sendable ([String], Int) async -> UpdatePasswordBuffer?
    static let shared = AppUpdateBatchAuthorization()
    private let prompt: Prompt
    private let makeChannel: @Sendable (UpdatePasswordBuffer) throws -> any AppUpdateAskpassServing
    private let command: any HomebrewCommandRunning
    private let mas: @Sendable () -> URL?
    private let brew: @Sendable () -> URL?
    private let captureExecutable: @Sendable (URL) throws -> AppUpdateExecutableIdentity
    private var frozenMas: AppUpdateExecutableIdentity?
    private var frozenBrew: AppUpdateExecutableIdentity?
    private var sourceFailures = [ApplicationUpdateProviderIdentifier: String]()
    private let prepareReplacement: @Sendable ([InstalledApplication], UUID, UpdatePasswordBuffer) async throws -> Void
    private let replaceApplication: @Sendable (URL, InstalledApplication, String) async throws -> Void
    private let finishReplacement: @Sendable () async -> Void
    private var channel: (any AppUpdateAskpassServing)?
    private var password: UpdatePasswordBuffer?
    private var sessionID: UUID?
    private var replacementFailure: String?
    private let lifetime = AppUpdateCredentialLifetime()
    init(prompt: @escaping Prompt = { commands, attempt in await MainActor.run { AppUpdatePasswordPrompt.request(commands: commands, attempt: attempt) } },
        makeChannel: @escaping @Sendable (UpdatePasswordBuffer) throws -> any AppUpdateAskpassServing = { try NativeUpdateAskpass(password: $0) },
        command: any HomebrewCommandRunning = AppUpdateCommandRunner(),
        mas: @escaping @Sendable () -> URL? = { MacAppStoreExecutableLocator.locate() },
        brew: @escaping @Sendable () -> URL? = { HomebrewInventoryScanner().locateHomebrewExecutable() },
        captureExecutable: @escaping @Sendable (URL) throws -> AppUpdateExecutableIdentity = AppUpdateExecutableIdentity.capture,
        prepareReplacement: @escaping @Sendable ([InstalledApplication], UUID, UpdatePasswordBuffer) async throws -> Void = { apps, id, password in
            try await AppUpdateProtectedApplicationAuthorization.shared.prepare(applications: apps, sessionID: id, password: password)
        },
        replaceApplication: @escaping @Sendable (URL, InstalledApplication, String) async throws -> Void = { candidate, app, digest in
            try await AppUpdateProtectedApplicationAuthorization.shared.replace(candidate: candidate, application: app, authenticatedSHA256: digest)
        }, finishReplacement: @escaping @Sendable () async -> Void = { await AppUpdateProtectedApplicationAuthorization.shared.finish() }) {
        self.prompt = prompt; self.makeChannel = makeChannel; self.command = command; self.mas = mas
        self.brew = brew; self.captureExecutable = captureExecutable
        self.prepareReplacement = prepareReplacement; self.replaceApplication = replaceApplication; self.finishReplacement = finishReplacement
    }
    func prepare(applications: [InstalledApplication], sessionID: UUID) async throws {
        if self.sessionID == sessionID, password?.isCleared == false { return }
        await finish()
        for provider in [ApplicationUpdateProviderIdentifier.homebrew, .macAppStore] where applications.contains(where: { $0.updateProvider == provider }) {
            let url = provider == .homebrew ? brew() : mas()
            do {
                guard let url else { throw AppUpdateAuthorizationError.sourceChanged("未找到来源") }
                let frozen = try captureExecutable(url)
                if provider == .homebrew { frozenBrew = frozen } else { frozenMas = frozen }
            } catch { sourceFailures[provider] = error.localizedDescription }
        }
        let admin = applications.filter { sourceFailures[$0.updateProvider] == nil && ($0.requiresAdministratorAuthorization || $0.homebrewMetadata?.needsAdministrator == true) }
        guard !admin.isEmpty else { self.sessionID = sessionID; return }
        let commands = Self.commands(applications: admin, mas: frozenMas?.url, brew: frozenBrew?.url)
        let protected = admin.filter { ![.homebrew, .macAppStore].contains($0.updateProvider) }
        for attempt in 1...3 {
            try Task.checkCancellation()
            guard let secret = await prompt(commands, attempt) else { throw AppUpdateAuthorizationError.declined }
            password = secret; lifetime.set(secret); AppUpdateCredentialRedactor.shared.set(secret)
            var validationPassed = false
            do {
                let channel = try makeChannel(secret)
                self.channel = channel
                // Invalidate any terminal timestamp first and immediately after
                // validation. Each batch requires the user's actual password.
                _ = try await command.run(executableURL: URL(fileURLWithPath: "/usr/bin/sudo"), arguments: ["-A", "-k", "-v"],
                    environment: baseEnvironment().merging(channel.environment) { _, new in new }, timeout: 30)
                validationPassed = true
                _ = try await command.run(executableURL: URL(fileURLWithPath: "/usr/bin/sudo"), arguments: ["-k"], environment: baseEnvironment(), timeout: 10)
                try Task.checkCancellation()
                if !protected.isEmpty {
                    do { try await prepareReplacement(protected, sessionID, secret) }
                    catch {
                        replacementFailure = error as? AuthorizedMoveError == .connectionLost
                            ? L10n.text("辅助程序握手或刷新超时，未开始替换", "Helper handshake/refresh timed out; replacement did not start")
                            : AppUpdateErrorRedaction.text(error.localizedDescription)
                    }
                }
                self.sessionID = sessionID
                return
            } catch {
                channel?.finish(); channel = nil; secret.clear(); password = nil; lifetime.set(nil); AppUpdateCredentialRedactor.shared.set(nil)
                // Only an authentication rejection is retriable. No installation
                // has started here. Registration/signature/cancellation fail closed.
                if case AppUpdateCommandError.failed = error, !validationPassed, attempt < 3 { continue }
                await finishReplacement()
                if case AppUpdateCommandError.failed = error, !validationPassed { throw AppUpdateAuthorizationError.incorrectPassword }
                if error is CancellationError { throw error }
                throw AppUpdateAuthorizationError.unavailable
            }
        }
        throw AppUpdateAuthorizationError.incorrectPassword
    }
    func homebrewEnvironment() async throws -> [String: String] {
        if let failure = sourceFailures[.homebrew] { throw AppUpdateAuthorizationError.sourceChanged(failure) }
        guard let channel, password?.isCleared == false else { throw AppUpdateAuthorizationError.declined }
        _ = try validate(frozenBrew)
        return channel.environment
    }
    func homebrewExecutable() async throws -> AppUpdateExecutableIdentity? {
        if let failure = sourceFailures[.homebrew] { throw AppUpdateAuthorizationError.sourceChanged(failure) }
        guard let frozenBrew else { return nil }
        _ = try validate(frozenBrew); return frozenBrew
    }
    func revokeHomebrewAuthorization() async throws {
        // -k from the App cannot revoke a brew-parent timestamp. -K is the
        // documented password-free operation covering every user timestamp.
        let command = command; let environment = baseEnvironment()
        _ = try await Task.detached(priority: .utility) {
            try await command.run(executableURL: URL(fileURLWithPath: "/usr/bin/sudo"), arguments: ["-K"], environment: environment, timeout: 10)
        }.value
    }
    private func validate(_ source: AppUpdateExecutableIdentity?) throws -> URL {
        guard let source, try captureExecutable(source.url) == source else { throw AppUpdateAuthorizationError.sourceChanged(source?.url.path ?? "未知来源") }
        return source.url
    }
    func upgrade(productID: UInt64) async throws {
        if let failure = sourceFailures[.macAppStore] { throw AppUpdateAuthorizationError.sourceChanged(failure) }
        guard productID > 0, let channel, password?.isCleared == false else { throw AppUpdateAuthorizationError.declined }
        let executable = try validate(frozenMas)
        do {
            _ = try await command.run(executableURL: URL(fileURLWithPath: "/usr/bin/sudo"),
                arguments: ["-A", "-k", executable.path, "upgrade", String(productID)],
                environment: baseEnvironment().merging(channel.environment) { _, new in new }, timeout: 30 * 60)
        } catch {
            // Preserve account-unavailable classification after redaction.
            if case let AppUpdateCommandError.failed(code, detail) = error {
                let redacted = AppUpdateCredentialRedactor.shared.redact(detail)
                throw AppUpdateCommandError.failed(code, redacted)
            }
            throw error
        }
    }
    func replace(candidate: URL, application: InstalledApplication) async throws {
        try checkReplacementAuthorization()
        // An unbound legacy call cannot recompute and substitute a new digest.
        throw AppUpdateAuthorizationError.unavailable
    }
    func replace(candidate: URL, application: InstalledApplication, authenticatedSHA256: String) async throws {
        try checkReplacementAuthorization()
        try Task.checkCancellation()
        try await replaceApplication(candidate, application, authenticatedSHA256)
    }
    private func checkReplacementAuthorization() throws {
        guard password?.isCleared == false else { throw AppUpdateAuthorizationError.declined }
        if let replacementFailure { throw AppUpdateAuthorizationError.helperUnavailable(replacementFailure) }
    }

    func finish() async {
        // Clear synchronously before awaiting helper acknowledgements.
        let hadBatch = sessionID != nil && password?.isCleared == false
        let hadBrew = frozenBrew != nil && hadBatch
        lifetime.set(nil); password?.clear(); password = nil; AppUpdateCredentialRedactor.shared.set(nil)
        channel?.finish(); channel = nil; sessionID = nil; replacementFailure = nil
        await finishReplacement()
        if hadBrew && hadBatch { try? await revokeHomebrewAuthorization() }
        frozenBrew = nil; frozenMas = nil; sourceFailures.removeAll()
        if hadBatch {
            // Revoke even when the caller's task is cancelled. This detached
            // invocation only invalidates a timestamp, never starts an installer.
            let executor = command; let environment = baseEnvironment()
            _ = try? await Task.detached(priority: .utility) {
                try await executor.run(executableURL: URL(fileURLWithPath: "/usr/bin/sudo"), arguments: ["-k"], environment: environment, timeout: 10)
            }.value
        }
    }
    private func baseEnvironment() -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(), "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8"]
    }
    static func commands(applications: [InstalledApplication], mas: URL?, brew: URL? = nil) -> [String] {
        var commands = [String]()
        let products = applications.filter { $0.updateProvider == .macAppStore }.compactMap { MacAppStoreAutomaticUpdateSupport.productIdentifier(from: $0.appStoreProductURL) }
        for product in Set(products).sorted() {
            let names = applications.filter { MacAppStoreAutomaticUpdateSupport.productIdentifier(from: $0.appStoreProductURL) == product }.map(\.displayName)
            commands.append("sudo -A -k \(mas?.path ?? "mas") upgrade \(product) · " + Set(names).sorted().joined(separator: "、"))
        }
        for app in applications where app.updateProvider == .homebrew {
            guard let metadata = app.homebrewMetadata else { continue }
            let greedy = metadata.effectiveOutdatedProvenance == .greedy ? " --greedy" : ""
            commands.append("\(brew?.path ?? "Homebrew 不可用") upgrade --\(metadata.kind.rawValue)\(greedy) \(metadata.token) · \(app.displayName)")
        }
        for kind in [HomebrewPackageKind.formula, .cask] {
            let packages = applications.filter { $0.updateProvider == .homebrew }.compactMap(\.homebrewMetadata).filter { $0.kind == kind }
            let tokens = packages.map(\.token).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if tokens.count > 1 {
                let greedy = kind == .cask && packages.contains(where: { $0.effectiveOutdatedProvenance == .greedy }) ? " --greedy" : ""
                commands.append("\(brew?.path ?? "Homebrew 不可用") upgrade --\(kind.rawValue)\(greedy) " + tokens.joined(separator: " "))
            }
        }
        commands += applications.filter { ![.homebrew, .macAppStore].contains($0.updateProvider) }.map { "替换 \($0.path) · \($0.displayName)" }
        return Array(Set(commands)).sorted()
    }
}

private final class AppUpdateCredentialLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var secret: UpdatePasswordBuffer?
    private var observation: NSObjectProtocol?
    init() {
        observation = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in self?.set(nil) }
    }
    func set(_ value: UpdatePasswordBuffer?) { lock.withLock { secret?.clear(); secret = value } }
    deinit { set(nil); if let observation { NotificationCenter.default.removeObserver(observation) } }
}

@MainActor private enum AppUpdatePasswordPrompt {
    static func request(commands: [String], attempt: Int) -> UpdatePasswordBuffer? {
        let alert = NSAlert()
        alert.messageText = L10n.text("授权本批软件更新", "Authorize this update batch")
        alert.informativeText = L10n.text("将以管理员身份运行以下命令／替换以下应用：\n", "The following commands/replacements require administrator access:\n")
            + commands.joined(separator: "\n") + "\n\n"
            + L10n.text("这些命令及其安装脚本将获得管理员权限，等同于在终端输入密码。允许本机 admin 组维护 Homebrew 来源。批量失败时可能按清单中的单项命令重试。不保存密码，批次结束停止提供密码，并撤销 sudo 缓存（包括其他终端的授权缓存）。", "These commands and their installation scripts receive administrator privileges, equivalent to entering a password in Terminal. Local administrators are trusted to maintain Homebrew sources. Failed groups may retry individual commands listed above. The password is not saved; at completion it is no longer supplied and sudo caches, including other Terminal authorizations, are revoked.")
            + (attempt > 1 ? L10n.text("\n密码验证失败，请重输（\(attempt)/3）。", "\nPassword verification failed; try again (\(attempt)/3).") : "")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        field.placeholderString = L10n.text("当前管理员密码", "Current administrator password")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("授权更新", "Authorize Updates"))
        alert.addButton(withTitle: L10n.text("取消授权", "Cancel Authorization"))
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        defer { field.stringValue = "" }
        guard response == .alertFirstButtonReturn else { return nil }
        var bytes = Array(field.stringValue.utf8)
        defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard !bytes.isEmpty, bytes.count < 4095, !bytes.contains(10), !bytes.contains(0) else { return nil }
        return UpdatePasswordBuffer(bytes: bytes)
    }
}

enum AppUpdateBundledCodeTrust {
    static func matchesApplication(_ url: URL, identifier: String) -> Bool {
        func certificates(_ url: URL, id: String) -> [SecCertificate]? {
            var code: SecStaticCode?; var info: CFDictionary?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
                SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                let values = info as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == id,
                let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty else { return nil }
            return certificates
        }
        guard let app = certificates(Bundle.main.bundleURL, id: FileOperationIdentity.application),
            let helper = certificates(url, id: identifier) else { return false }
        return app == helper
    }
}

final class AppUpdateCredentialRedactor: @unchecked Sendable {
    static let shared = AppUpdateCredentialRedactor()
    private let lock = NSLock()
    private var password: UpdatePasswordBuffer?
    func set(_ password: UpdatePasswordBuffer?) { lock.withLock { self.password = password } }
    func redact(_ input: String) -> String {
        var bytes = Data(input.utf8)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return redact(bytes: bytes)
    }
    func redact(bytes input: Data) -> String {
        var source = Array(input)
        var result = [UInt8]()
        defer {
            source.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
            result.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        }
        lock.withLock {
            func process(_ secret: UnsafeRawBufferPointer) {
                var index = 0
                while index < source.count {
                    if !secret.isEmpty, source.count - index >= secret.count,
                       (0..<secret.count).allSatisfy({ source[index + $0] == secret[$0] }) {
                        result.append(contentsOf: "[已隐去]".utf8); index += secret.count
                    } else { result.append(source[index]); index += 1 }
                }
            }
            if let password { password.withBytes(process) } else { process(.init(start: nil, count: 0)) }
        }
        return AppUpdateErrorRedaction.text(String(decoding: result, as: UTF8.self))
    }
}
