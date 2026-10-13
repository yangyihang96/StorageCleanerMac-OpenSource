import Foundation

struct VendorUpdateCommand: Hashable, Sendable {
    enum Kind: Sendable { case microsoft, google }
    let kind: Kind
    let executableURL: URL
    let productID: String
    var installArguments: [String] {
        switch kind {
        case .microsoft: ["--install", "--apps", productID, "--wait", "1800"]
        case .google: ["--update", "--productid", productID]
        }
    }
}

struct VendorCommandUpdateAdapter: Sendable {
    var resolve: @Sendable (InstalledApplication) async -> VendorUpdateCommand? = { app in
        let microsoftIDs = ["com.microsoft.Word": "MSWD2019", "com.microsoft.Excel": "XCEL2019", "com.microsoft.Powerpoint": "PPT32019",
            "com.microsoft.Outlook": "OPIM2019", "com.microsoft.onenote.mac": "ONMC2019", "com.microsoft.wdav": "WDAV00"]
        var candidates = [VendorUpdateCommand]()
        if app.signingTeamIdentifier == "UBF8T346G9", let id = microsoftIDs[app.bundleIdentifier] {
            candidates.append(.init(kind: .microsoft, executableURL: URL(fileURLWithPath:
                "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"), productID: id))
        }
        if app.signingTeamIdentifier == "EQHXZ8M8AV",
           let info = NSDictionary(contentsOf: app.bundleURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
           let id = info["KSProductID"] as? String, id == app.bundleIdentifier {
            for base in ["/Library/Google", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Google").path] {
                candidates.append(.init(kind: .google, executableURL: URL(fileURLWithPath:
                    base + "/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/MacOS/ksadmin"), productID: id))
            }
        }
        for command in candidates {
            guard FileManager.default.isExecutableFile(atPath: command.executableURL.path),
                  let signature = try? CodeSignatureVerifier().verifyCode(at: command.executableURL), signature.isValid,
                  signature.teamIdentifier == app.signingTeamIdentifier else { continue }
            return command
        }
        return nil
    }
    var run: @Sendable (URL, [String]) async throws -> Data = { url, args in
        try await AppUpdateCommandRunner().run(executableURL: url, arguments: args,
            environment: HomebrewCommandEnvironment.allowlist(executableURL: url, environment: ProcessInfo.processInfo.environment), timeout: 30 * 60)
    }

    func check(_ application: InstalledApplication, command: VendorUpdateCommand) async throws -> ApplicationVersion? {
        guard command.kind == .microsoft else { return nil }
        let data = try await run(command.executableURL, ["--list", "--format", "plist"])
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        return Self.version(in: root, productID: command.productID)
    }
    private static func version(in value: Any, productID: String) -> ApplicationVersion? {
        if let list = value as? [Any] { return list.compactMap { version(in: $0, productID: productID) }.first }
        guard let dict = value as? [String: Any] else { return nil }
        let identifier = dict["ApplicationID"] as? String ?? dict["AppID"] as? String ?? dict["Identifier"] as? String
        if identifier == productID, let version = dict["Version"] as? String ?? dict["LatestVersion"] as? String ?? dict["AppVersion"] as? String { return .init(marketing: version) }
        return dict.values.compactMap { version(in: $0, productID: productID) }.first
    }
}
