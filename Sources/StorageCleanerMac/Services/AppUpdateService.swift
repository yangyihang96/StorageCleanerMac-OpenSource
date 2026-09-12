import AppKit
import Foundation

enum AppUpdateService {
    static func scanInstalledApps(
        limit: Int = 180,
        configuration: AppUpdateSourceConfiguration = AppUpdateSourcePreferences.configuration()
    ) -> [AppUpdateItem] {
        let folders = ["/Applications", "\(NSHomeDirectory())/Applications"]
        let homebrewCasks = configuration.includes(.homebrew) ? homebrewCasksByAppPath() : [:]
        let homebrewOutdated = configuration.includes(.homebrew) ? homebrewOutdatedByToken() : [:]
        let appStoreOutdated = configuration.includes(.appStore) ? appStoreOutdatedByBundleIdentifier() : [:]
        var apps = [AppUpdateItem]()

        for folder in folders {
            apps.append(contentsOf: scanApps(
                in: folder,
                homebrewCasks: homebrewCasks,
                homebrewOutdated: homebrewOutdated,
                appStoreOutdated: appStoreOutdated
            ))
        }

        return Array(confirmedUpdateCandidates(apps, configuration: configuration).prefix(limit))
    }

    static func confirmedUpdateCandidates(
        _ apps: [AppUpdateItem],
        configuration: AppUpdateSourceConfiguration = .all
    ) -> [AppUpdateItem] {
        apps
            .filter { configuration.includes($0.method) && isConfirmedUpdate($0) }
            .sorted {
                if $0.method.rawValue == $1.method.rawValue {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return methodRank($0.method) < methodRank($1.method)
            }
    }

    static func isConfirmedUpdate(_ app: AppUpdateItem) -> Bool {
        let latest = app.latestVersion?.trimmed ?? ""
        guard !latest.isEmpty else { return false }

        let current = app.currentVersion?.trimmed ?? ""
        let displayedCurrent = current.isEmpty ? app.versionDisplay : current
        guard !displayedCurrent.trimmed.isEmpty else { return true }

        return normalizedVersionKey(displayedCurrent) != normalizedVersionKey(latest)
    }

    @MainActor
    static func openUpdateEntry(for app: AppUpdateItem) -> String {
        if app.updateProvider == .systemManaged {
            let destinations = [
                URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"),
                URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            ].compactMap { $0 }
            guard destinations.contains(where: NSWorkspace.shared.open) else {
                return L10n.text(
                    "无法打开系统软件更新；尚未执行任何更新",
                    "Could not open Software Update; no update was performed"
                )
            }
            return L10n.text(
                "已打开系统软件更新；此软件随 macOS 更新，不会单独替换",
                "Opened Software Update; this software is updated with macOS and is not replaced separately"
            )
        }

        if app.updateProvider == .officialWebsite,
           app.officialSource != nil {
            guard let url = validatedOfficialWebsiteURL(for: app),
                  NSWorkspace.shared.open(url) else {
                return L10n.text(
                    "官网来源尚未通过验证，未打开任何下载地址",
                    "The website source is not verified; no download address was opened"
                )
            }
            return L10n.text(
                "已打开 \(url.host ?? "官方更新页")；完成后重新扫描，版本变化后才会标记成功",
                "Opened \(url.host ?? "the official update page"); rescan afterwards, and completion requires a version change"
            )
        }

        if case .manual = ApplicationUpdatePlanBuilder.destination(for: app),
           let url = validatedManualUpdateURL(for: app) {
            guard NSWorkspace.shared.open(url) else {
                return L10n.text(
                    "无法打开已验证的手动更新页面，尚未执行任何更新",
                    "Could not open the verified manual update page; no update was performed"
                )
            }
            return L10n.text(
                "已打开 \(url.host ?? "官方更新页")；请手动完成更新后重新扫描版本",
                "Opened \(url.host ?? "the official update page"); finish the update manually, then rescan the installed version"
            )
        }

        switch app.method {
        case .appStore:
            if let productURL = validatedAppStoreProductURL(for: app) {
                guard NSWorkspace.shared.open(productURL) else {
                    return L10n.text(
                        "无法打开该应用的 App Store 产品页，尚未执行任何更新",
                        "Could not open this app's App Store product page; no update was performed"
                    )
                }
                return L10n.text(
                    "已打开该应用的 App Store 产品页；请确认更新，完成后重新扫描版本",
                    "Opened this app's App Store product page; confirm the update, then rescan the installed version"
                )
            }
            guard openAppStoreUpdates() else {
                return L10n.text(
                    "无法打开 App Store，尚未执行任何更新",
                    "Could not open the App Store; no update was performed"
                )
            }
            return L10n.text(
                "已打开 App Store；请进入“更新”检查并确认，完成后重新扫描版本",
                "Opened the App Store; check and confirm under Updates, then rescan the installed version"
            )
        case .homebrew:
            let command = app.homebrewCommand ?? "brew outdated --cask"
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(command, forType: .string) else {
                return L10n.text(
                    "无法复制 Homebrew 更新命令，尚未执行任何更新",
                    "Could not copy the Homebrew update command; no update was performed"
                )
            }
            return L10n.text(
                "已复制 Homebrew 更新命令：\(command)。复制不代表已执行，需在终端确认后重新扫描",
                "Copied Homebrew update command: \(command). Copying does not run it; confirm in Terminal and rescan"
            )
        case .sparkle, .manual:
            guard NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) else {
                return L10n.text(
                    "无法打开 \(app.method.title) 更新入口，尚未执行任何更新",
                    "Could not open the \(app.method.title) update entry; no update was performed"
                )
            }
            return L10n.text(
                "已打开 \(app.method.title) 更新入口，仍需在应用内或官网确认；完成后重新扫描",
                "Opened the \(app.method.title) update entry; confirm in the app or website, then rescan"
            )
        }
    }

    static func validatedOfficialWebsiteURL(for app: AppUpdateItem) -> URL? {
        guard app.updateProvider == .officialWebsite else { return nil }
        return validatedManualUpdateURL(for: app)
    }

    static func validatedManualUpdateURL(for app: AppUpdateItem) -> URL? {
        guard let source = app.officialSource,
              source.trustLevel >= .userConfirmed,
              source.capability != .sourceConfirmation,
              source.applicationIdentity == app.identity,
              let url = source.updatePageURL ?? source.homepageURL,
              (try? AllowedHostValidator().validate(
                url,
                allowedHosts: source.allowedHosts
              )) != nil else {
            return nil
        }
        return url
    }

    static func validatedAppStoreProductURL(for app: AppUpdateItem) -> URL? {
        guard app.updateProvider == .macAppStore,
              let url = app.appStoreProductURL,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let host = url.host?.lowercased(),
              host == "apps.apple.com" || host == "itunes.apple.com" else {
            return nil
        }
        return url
    }

    static func oneClickPlan(for apps: [AppUpdateItem]) -> AppUpdateOneClickPlan {
        let plan = ApplicationUpdatePlanBuilder().build(applications: apps)
        let appsByID = Dictionary(
            apps.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let applications: ([String]) -> [AppUpdateItem] = { ids in
            ids.compactMap { appsByID[$0] }
        }
        let manual = applications(plan.manualApplicationIDs)
        return AppUpdateOneClickPlan(
            appStoreApps: applications(plan.appStoreApplicationIDs),
            automaticApps: applications(
                plan.automaticApplicationIDs + plan.requiresQuitApplicationIDs
            ),
            authorizationApps: applications(plan.requiresAuthorizationApplicationIDs),
            sparkleApps: manual.filter {
                $0.updateProvider == .sparkle || $0.updateProvider == .vendorUpdater
            },
            manualApps: applications(plan.websiteApplicationIDs) + manual.filter {
                $0.updateProvider != .sparkle && $0.updateProvider != .vendorUpdater
            }
        )
    }

    static func homebrewUpgradeArguments(for apps: [AppUpdateItem]) -> [String] {
        let tokens = uniqueCaskTokens(for: apps)
        guard !tokens.isEmpty else { return [] }
        return ["upgrade", "--cask"] + tokens
    }

    static func homebrewUpgradeCommand(for apps: [AppUpdateItem]) -> String? {
        let arguments = homebrewUpgradeArguments(for: apps)
        guard !arguments.isEmpty else { return nil }
        return (["brew"] + arguments).joined(separator: " ")
    }

    @MainActor
    static func prepareOneClickUpdate(_ plan: AppUpdateOneClickPlan, opensAppStore: Bool = true) -> AppUpdateOneClickLaunchResult {
        let shouldOpenAppStore = opensAppStore && !plan.appStoreApps.isEmpty
        let openedAppStore = shouldOpenAppStore && openAppStoreUpdates()

        let reviewList = manualReviewList(for: plan)
        var copiedManualReviewList = false
        if !reviewList.isEmpty {
            NSPasteboard.general.clearContents()
            copiedManualReviewList = NSPasteboard.general.setString(reviewList, forType: .string)
        }

        return AppUpdateOneClickLaunchResult(
            openedAppStore: openedAppStore,
            copiedManualReviewList: copiedManualReviewList
        )
    }

    static func appStoreRunResult(
        for plan: AppUpdateOneClickPlan,
        launched: AppUpdateOneClickLaunchResult
    ) -> AppUpdateAppStoreRunResult {
        guard !plan.appStoreApps.isEmpty else {
            return AppUpdateAppStoreRunResult(
                status: .skipped,
                command: nil,
                detail: L10n.text("没有 App Store 应用需要处理。", "No App Store apps to process.")
            )
        }

        guard launched.openedAppStore else {
            return AppUpdateAppStoreRunResult(
                status: .failed,
                command: nil,
                detail: L10n.text(
                    "未能打开 App Store；请手动打开后在“更新”中检查。",
                    "Could not open the App Store; open it manually and check under Updates."
                )
            )
        }

        return AppUpdateAppStoreRunResult(
            status: .opened,
            command: nil,
            detail: L10n.text(
                "已打开 App Store；请进入“更新”检查，需要授权时由系统窗口确认。",
                "Opened the App Store; check under Updates and confirm in the system window if authorization is needed."
            )
        )
    }

    static func runHomebrewUpgrade(
        for apps: [AppUpdateItem],
        brewPath: String? = nil,
        timeoutSeconds: TimeInterval = 600
    ) -> AppUpdateHomebrewRunResult {
        let arguments = homebrewUpgradeArguments(for: apps)
        let command = homebrewUpgradeCommand(for: apps)

        guard !arguments.isEmpty else {
            return AppUpdateHomebrewRunResult(
                status: .skipped,
                command: command,
                detail: L10n.text("没有 Homebrew Cask 应用需要处理。", "No Homebrew Cask apps to process.")
            )
        }

        guard let executable = brewPath ?? brewExecutablePath() else {
            return AppUpdateHomebrewRunResult(
                status: .unavailable,
                command: command,
                detail: L10n.text("未找到 Homebrew。", "Homebrew was not found.")
            )
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return AppUpdateHomebrewRunResult(
                status: .unavailable,
                command: command,
                detail: L10n.text("Homebrew 路径不可执行：\(executable)", "Homebrew path is not executable: \(executable)")
            )
        }

        do {
            let output = try Shell.capture(executable, arguments, timeout: timeoutSeconds)
            return AppUpdateHomebrewRunResult(
                status: .succeeded,
                command: command,
                detail: output.trimmed.isEmpty
                    ? L10n.text(
                        "Homebrew 更新命令已完成；重新检查更新列表确认版本。",
                        "Homebrew update command completed; rescan updates to confirm versions."
                    )
                    : output.trimmed
            )
        } catch let ShellError.failed(_, _, output) where needsInteractiveTerminal(output) {
            return AppUpdateHomebrewRunResult(
                status: .needsTerminal,
                command: command,
                detail: L10n.text(
                    "Homebrew 需要终端授权。已准备改用终端脚本继续处理；请在终端窗口按系统要求确认。",
                    "Homebrew needs Terminal authorization. A Terminal script is required to continue; confirm in the Terminal window if macOS asks."
                )
            )
        } catch let ShellError.timedOut(_, timeout) {
            return AppUpdateHomebrewRunResult(
                status: .timedOut,
                command: command,
                detail: L10n.text("Homebrew 更新超过 \(Int(timeout)) 秒，已停止等待。", "Homebrew update exceeded \(Int(timeout)) seconds; stopped waiting.")
            )
        } catch {
            return AppUpdateHomebrewRunResult(
                status: .failed,
                command: command,
                detail: error.localizedDescription
            )
        }
    }

    static func shouldContinueHomebrewInTerminal(_ result: AppUpdateHomebrewRunResult) -> Bool {
        result.status == .needsTerminal
    }

    static func needsInteractiveTerminal(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        let markers = [
            "sudo: a terminal is required",
            "sudo: a password is required",
            "a terminal is required to read the password",
            "no tty present",
            "conversation error",
            "authentication is required",
            "requires root privileges",
            "password is required"
        ]
        return markers.contains { lowercased.contains($0) }
    }

    static func oneClickSummary(result: AppUpdateOneClickResult) -> String {
        let statuses = [result.appStore.status, result.automatic.status]
        if statuses.contains(.failed) {
            return L10n.text("批量更新处理中有步骤失败", "Batch update processing had a failed step")
        }
        if statuses.contains(.timedOut) {
            return L10n.text("批量更新已执行，但有更新命令超时", "Batch update ran, but an update command timed out")
        }
        if statuses.contains(.needsTerminal) {
            return L10n.text("Homebrew 需要在终端中确认", "Homebrew needs confirmation in Terminal")
        }
        if statuses.contains(.unavailable) || statuses.contains(.opened) {
            return L10n.text(
                "已打开需要系统确认的更新入口，尚未确认版本已更新",
                "Opened update entries that need system confirmation; versions are not confirmed updated yet"
            )
        }
        if statuses.contains(.launched) {
            return L10n.text(
                "已在终端启动批量更新，仍需按终端提示完成后重新检查",
                "Batch update launched in Terminal; finish the Terminal prompts and check again"
            )
        }
        if statuses.contains(.succeeded) {
            return L10n.text(
                "批量更新命令已完成，重新检查确认版本",
                "Batch update commands completed; check again to confirm versions"
            )
        }
        return result.launched.copiedManualReviewList
            ? L10n.text(
                "已复制需要人工确认的更新清单，复制不代表已更新",
                "Copied update entries that need manual confirmation; copying does not update them"
            )
            : L10n.text("没有可批量处理的更新来源", "No update sources can be processed in batch")
    }

    static func manualReviewList(for plan: AppUpdateOneClickPlan) -> String {
        let apps = plan.sparkleApps + plan.manualApps
        guard !apps.isEmpty else { return "" }

        let lines = apps.map { app in
            "- \(app.name) [\(app.method.title)] \(app.versionDisplay) \(app.path)"
        }

        return ([L10n.text("需要人工确认的更新：", "Updates that need manual confirmation:")] + lines).joined(separator: "\n")
    }

    @MainActor
    @discardableResult
    static func openAppStoreUpdates() -> Bool {
        let destinations = [
            URL(string: "macappstore://showUpdatesPage"),
            URL(fileURLWithPath: "/System/Applications/App Store.app"),
        ].compactMap { $0 }
        return destinations.contains(where: NSWorkspace.shared.open)
    }

    static func versionDisplay(shortVersion: String, buildVersion: String) -> String {
        let short = shortVersion.trimmed
        let build = buildVersion.trimmed

        if short.isEmpty && build.isEmpty {
            return L10n.text("未知版本", "Unknown Version")
        }
        if short.isEmpty {
            return build
        }
        if build.isEmpty || build == short {
            return short
        }
        return "\(short) (\(build))"
    }

    static func appStoreOutdatedByBundleIdentifier(from output: String) -> [String: AppStoreOutdatedInfo] {
        jsonObjects(fromLineDelimitedJSON: output).reduce(into: [String: AppStoreOutdatedInfo]()) { result, object in
            let bundleID = (object["bundleID"] as? String ?? object["bundleIdentifier"] as? String ?? "").trimmed
            let currentVersion = (object["version"] as? String ?? "").trimmed
            let latestVersion = (object["newVersion"] as? String ?? "").trimmed
            guard !bundleID.isEmpty, !currentVersion.isEmpty, !latestVersion.isEmpty else { return }
            result[bundleID] = AppStoreOutdatedInfo(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                productID: (object["adamID"] as? NSNumber)?.uint64Value,
                bundleURL: (object["path"] as? String)?.trimmed.nonEmpty.map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                }
            )
        }
    }

    static func mergingAppStoreOutdated(
        _ updates: [String: AppStoreOutdatedInfo],
        into apps: [AppUpdateItem]
    ) -> [AppUpdateItem] {
        apps.map { app in
            guard app.primaryUpdateProvider == .macAppStore,
                  let update = updates[app.bundleIdentifier] else {
                return app
            }
            let currentVersion = ApplicationVersion(marketing: update.currentVersion)
            let latestVersion = ApplicationVersion(marketing: update.latestVersion)
            guard currentVersion < latestVersion else { return app }

            var item = app
            item.reportedCurrentVersion = update.currentVersion
            item.availableVersion = latestVersion
            item.versionCheckState = .updateAvailable
            if !item.sourceEvidence.contains("mas-outdated") {
                item.sourceEvidence.append("mas-outdated")
            }
            if let productID = update.productID {
                let evidence = "\(MacAppStoreAutomaticUpdateSupport.evidencePrefix)\(productID)"
                if !item.sourceEvidence.contains(evidence) {
                    item.sourceEvidence.append(evidence)
                }
                if item.appStoreProductURL == nil {
                    item.appStoreProductURL = MacAppStoreAutomaticUpdateSupport.productURL(
                        for: productID
                    )
                }
            }
            let hasTrustedMas = MacAppStoreExecutableLocator.locate() != nil
            if hasTrustedMas, !item.sourceEvidence.contains("mas-executable-trusted") {
                item.sourceEvidence.append("mas-executable-trusted")
            }
            let canAutomaticallyUpdate = hasTrustedMas
                && MacAppStoreAutomaticUpdateSupport.matchingRecord(
                    for: item,
                    in: [item.bundleIdentifier: update]
                ) != nil
                && update.productID == MacAppStoreAutomaticUpdateSupport.productIdentifier(
                    from: item.appStoreProductURL
                )
                && item.identity.isCompleteForAutomaticUpdates
                && item.sourceEvidence.contains("verified-app-store-receipt")
                && item.sourceEvidence.contains("valid-code-signature")
                && item.sourceEvidence.contains("signed-bundle-identity")
            item.updateStatus = canAutomaticallyUpdate ? .automaticallyUpdatable : .updateAvailable
            item.updateCapability = canAutomaticallyUpdate ? .automatic : .appStoreManaged
            item.canAutomaticallyUpdate = canAutomaticallyUpdate
            item.requiresUserInteraction = !canAutomaticallyUpdate
            item.updateError = canAutomaticallyUpdate ? nil : L10n.text(
                "请在 App Store 中确认更新。",
                "Confirm the update in the App Store."
            )
            return item
        }
    }

    static func homebrewOutdatedByToken(from output: String) -> [String: HomebrewOutdatedInfo] {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else {
            return [:]
        }

        return casks.reduce(into: [String: HomebrewOutdatedInfo]()) { result, cask in
            let token = (cask["name"] as? String ?? cask["token"] as? String ?? "").trimmed
            let latestVersion = (cask["current_version"] as? String ?? cask["version"] as? String ?? "").trimmed
            let installedVersion = installedVersion(from: cask["installed_versions"] ?? cask["installed"]).trimmed
            guard !token.isEmpty, !latestVersion.isEmpty else { return }
            result[token] = HomebrewOutdatedInfo(
                installedVersion: installedVersion,
                latestVersion: latestVersion
            )
        }
    }

    static func updateMethod(
        for info: [String: Any],
        hasAppStoreReceipt: Bool,
        homebrewToken: String? = nil
    ) -> AppUpdateMethod {
        if hasAppStoreReceipt {
            return .appStore
        }

        if homebrewToken?.trimmed.isEmpty == false {
            return .homebrew
        }

        if sparkleFeedURL(in: info) != nil {
            return .sparkle
        }

        return .manual
    }

    static func sparkleFeedURL(in info: [String: Any]) -> String? {
        let keys = ["SUFeedURL", "SUFeedURLForSparkle", "SparkleFeedURL"]
        return keys
            .compactMap { info[$0] as? String }
            .first { !$0.trimmed.isEmpty }
    }

    private static func scanApps(
        in folder: String,
        homebrewCasks: [String: HomebrewCaskInfo],
        homebrewOutdated: [String: HomebrewOutdatedInfo],
        appStoreOutdated: [String: AppStoreOutdatedInfo]
    ) -> [AppUpdateItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard url.pathExtension == "app" else { return nil }
            let homebrewCask = homebrewCasks[PathSafety.normalizedPath(url.path)] ?? homebrewCasks[appNameKey(url.lastPathComponent)]
            return appUpdateItem(
                for: url,
                source: folder == "/Applications" ? L10n.text("系统应用目录", "System Applications") : L10n.text("用户应用目录", "User Applications"),
                homebrewCask: homebrewCask,
                homebrewOutdated: homebrewCask.flatMap { homebrewOutdated[$0.token] },
                appStoreOutdated: appStoreOutdated
            )
        }
    }

    private static func appUpdateItem(
        for url: URL,
        source: String,
        homebrewCask: HomebrewCaskInfo?,
        homebrewOutdated: HomebrewOutdatedInfo?,
        appStoreOutdated: [String: AppStoreOutdatedInfo]
    ) -> AppUpdateItem {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOf: infoURL) as? [String: Any] ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String ?? ""
        let displayName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let hasReceipt = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        let method = updateMethod(for: info, hasAppStoreReceipt: hasReceipt, homebrewToken: homebrewCask?.token)
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let appStoreInfo = appStoreOutdated[bundleID]
        let currentVersion: String?
        let latestVersion: String?

        switch method {
        case .appStore:
            currentVersion = appStoreInfo?.currentVersion
            latestVersion = appStoreInfo?.latestVersion
        case .homebrew:
            currentVersion = homebrewOutdated?.installedVersion
            latestVersion = homebrewOutdated?.latestVersion
        case .sparkle, .manual:
            currentVersion = nil
            latestVersion = nil
        }

        return AppUpdateItem(
            id: PathSafety.normalizedPath(url.path),
            name: displayName,
            bundleIdentifier: bundleID,
            path: url.path,
            version: version,
            build: build,
            source: homebrewCask == nil ? source : L10n.text("Homebrew Cask", "Homebrew Cask"),
            method: method,
            feedURL: sparkleFeedURL(in: info),
            caskToken: homebrewCask?.token,
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            modifiedAt: modifiedAt
        )
    }

    private static func methodRank(_ method: AppUpdateMethod) -> Int {
        switch method {
        case .appStore: 0
        case .homebrew: 1
        case .sparkle: 2
        case .manual: 3
        }
    }

    private static func uniqueCaskTokens(for apps: [AppUpdateItem]) -> [String] {
        Array(Set(apps.compactMap { app -> String? in
            guard let token = app.caskToken?.trimmed, !token.isEmpty else { return nil }
            return token
        }))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func homebrewCasksByAppPath() -> [String: HomebrewCaskInfo] {
        guard let brewPath = brewExecutablePath(),
              let output = runCommand(brewPath, ["info", "--cask", "--json=v2", "--installed"], timeoutSeconds: 5),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else {
            return [:]
        }

        var casksByPath = [String: HomebrewCaskInfo]()
        for cask in casks {
            let token = cask["token"] as? String ?? ""
            guard !token.trimmed.isEmpty else { continue }

            let name = (cask["name"] as? [String])?.first ?? token
            let info = HomebrewCaskInfo(
                token: token,
                name: name,
                installedVersion: installedVersion(from: cask["installed"]),
                currentVersion: cask["version"] as? String ?? ""
            )

            for path in appPaths(from: cask) {
                casksByPath[PathSafety.normalizedPath(path)] = info
                casksByPath[appNameKey(URL(fileURLWithPath: path).lastPathComponent)] = info
            }
        }
        return casksByPath
    }

    static func appStoreOutdatedByBundleIdentifier() -> [String: AppStoreOutdatedInfo] {
        guard let masPath = masExecutablePath(),
              let output = try? Shell.captureCancellable(
                masPath,
                ["outdated", "--json"],
                timeout: 20,
                outputByteLimit: 2 * 1_024 * 1_024,
                cancellationCheck: { Task.isCancelled }
              ) else {
            return [:]
        }
        return appStoreOutdatedByBundleIdentifier(from: output)
    }

    private static func homebrewOutdatedByToken() -> [String: HomebrewOutdatedInfo] {
        guard let brewPath = brewExecutablePath(),
              let output = runCommand(brewPath, ["outdated", "--cask", "--json=v2"], timeoutSeconds: 20) else {
            return [:]
        }
        return homebrewOutdatedByToken(from: output)
    }

    static func masExecutablePath(fileManager: FileManager = .default) -> String? {
        ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    static func brewExecutablePath(fileManager: FileManager = .default) -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func executablePath(_ path: String?, fileManager: FileManager = .default) -> String? {
        guard let path, fileManager.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private static func pairedMasPath(forBrewPath brewPath: String, fileManager: FileManager = .default) -> String? {
        let path = URL(fileURLWithPath: brewPath)
            .deletingLastPathComponent()
            .appendingPathComponent("mas")
            .path
        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }

    private static func normalizedVersionKey(_ value: String) -> String {
        value
            .trimmed
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    private static func jsonObjects(fromLineDelimitedJSON output: String) -> [[String: Any]] {
        let trimmed = output.trimmed
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }

        return trimmed
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
    }

    private static func installedVersion(from value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let strings = value as? [String] {
            return strings.first ?? ""
        }
        return ""
    }

    private static func appPaths(from cask: [String: Any]) -> [String] {
        guard let artifacts = cask["artifacts"] as? [[String: Any]] else { return [] }

        var paths = [String]()
        for artifact in artifacts {
            if let target = artifact["target"] as? String, target.hasSuffix(".app") {
                paths.append((target as NSString).expandingTildeInPath)
            }

            guard let apps = artifact["app"] as? [Any] else { continue }
            for app in apps {
                if let appName = app as? String, appName.hasSuffix(".app") {
                    paths.append("/Applications/\(appName)")
                    paths.append("\(NSHomeDirectory())/Applications/\(appName)")
                }
            }
        }

        return paths
    }

    private static func appNameKey(_ appName: String) -> String {
        "app-name:" + appName.lowercased()
    }

    private static func runCommand(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval
    ) -> String? {
        do {
            let result = try Shell.run(executable, arguments, timeout: timeoutSeconds)
            return result.terminationStatus == 0 ? result.standardOutput : nil
        } catch {
            return nil
        }
    }
}

enum AppUpdateSourcePreferences {
    static let defaultsKey = "appUpdate.enabledSources"

    static func configuration(defaults: UserDefaults = .standard) -> AppUpdateSourceConfiguration {
        guard let rawValues = defaults.array(forKey: defaultsKey) as? [String] else {
            return .all
        }

        return AppUpdateSourceConfiguration(
            enabledMethods: Set(rawValues.compactMap(AppUpdateMethod.init(rawValue:)))
        )
    }

    static func setConfiguration(
        _ configuration: AppUpdateSourceConfiguration,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            configuration.enabledMethods
                .map(\.rawValue)
                .sorted(),
            forKey: defaultsKey
        )
    }

    static func set(
        _ method: AppUpdateMethod,
        isEnabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        var configuration = configuration(defaults: defaults)
        configuration.set(method, isEnabled: isEnabled)
        setConfiguration(configuration, defaults: defaults)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

private struct HomebrewCaskInfo {
    let token: String
    let name: String
    let installedVersion: String
    let currentVersion: String
}

struct AppStoreOutdatedInfo: Equatable, Sendable {
    let currentVersion: String
    let latestVersion: String
    let productID: UInt64?
    let bundleURL: URL?

    init(
        currentVersion: String,
        latestVersion: String,
        productID: UInt64? = nil,
        bundleURL: URL? = nil
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.productID = productID
        self.bundleURL = bundleURL
    }
}

struct HomebrewOutdatedInfo: Equatable {
    let installedVersion: String
    let latestVersion: String
}
