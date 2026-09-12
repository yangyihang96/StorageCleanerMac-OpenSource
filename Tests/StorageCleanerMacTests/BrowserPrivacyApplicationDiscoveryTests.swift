import CSQLite
import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class BrowserPrivacyApplicationDiscoveryTests: XCTestCase {
    func testInstalledBrowserCarriesLocalSigningEvidence() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try makeApplication(
            in: home,
            bundleIdentifier: "com.example.identity-browser",
            displayName: "Identity Browser"
        )
        let identity = StartupApplicationSigningIdentity(
            teamIdentifier: "TEAM-IDENTITY",
            codeSigningIdentifier: "com.example.identity-browser",
            designatedRequirement: "identifier \"com.example.identity-browser\""
        )

        let applications = await BrowserPrivacyApplicationLocator
            .discoverWithSigningIdentity(
                homeDirectory: home,
                identityReader: FixedSigningIdentityReader(identity: identity)
            )
        let discovered = try XCTUnwrap(
            applications.first { $0.bundleIdentifier == "com.example.identity-browser" }
        )

        XCTAssertEqual(discovered.url, app)
        XCTAssertEqual(discovered.displayName, "Identity Browser")
        XCTAssertEqual(discovered.signingIdentity, identity)
    }

    func testUnknownChromiumAndFirefoxDerivativesAreReadOnlyProviders() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let chromiumApp = try makeApplication(
            in: home,
            bundleIdentifier: "com.example.acme-browser",
            displayName: "Acme Browser"
        )
        let firefoxApp = try makeApplication(
            in: home,
            bundleIdentifier: "com.example.acme-fox",
            displayName: "Acme Fox"
        )

        let chromiumHistory = home.appendingPathComponent(
            "Library/Application Support/Acme Browser/Default/History"
        )
        try makeSQLiteDatabase(at: chromiumHistory, statements: [
            "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT)",
            "CREATE TABLE visits(url INTEGER, visit_time INTEGER)",
        ])
        let firefoxHistory = home.appendingPathComponent(
            "Library/Application Support/Acme Fox/Profiles/work/places.sqlite"
        )
        try makeSQLiteDatabase(at: firefoxHistory, statements: [
            "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT)",
            "CREATE TABLE moz_historyvisits(place_id INTEGER, visit_date INTEGER)",
        ])
        try Data("""
        [Profile0]
        Name=Work
        IsRelative=1
        Path=Profiles/work
        Default=1
        """.utf8).write(
            to: firefoxHistory
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("profiles.ini")
        )

        let applications = await BrowserPrivacyApplicationLocator
            .discoverWithSigningIdentity(
                homeDirectory: home,
                identityReader: MapSigningIdentityReader(identities: [
                    chromiumApp.path: StartupApplicationSigningIdentity(
                        teamIdentifier: "TEAM-ACME",
                        codeSigningIdentifier: "com.example.acme-browser",
                        designatedRequirement: nil
                    ),
                    firefoxApp.path: StartupApplicationSigningIdentity(
                        teamIdentifier: "TEAM-ACME",
                        codeSigningIdentifier: "com.example.acme-fox",
                        designatedRequirement: nil
                    ),
                ])
            )
        let discoveries = BrowserPrivacyProviderRegistry().discover(
            homeDirectory: home,
            installedApplications: applications
        )

        let chromium = try XCTUnwrap(discoveries.first {
            $0.coverage.browser.id == "discovered.com.example.acme.browser"
        })
        let registry = BrowserPrivacyProviderRegistry()
        XCTAssertEqual(chromium.coverage.browser.engine, .chromium)
        XCTAssertEqual(chromium.profiles.map(\.historyDatabaseURL.path), [chromiumHistory.path])
        XCTAssertNil(
            registry.allProviders(
                homeDirectory: home,
                installedApplications: applications
            ).first { $0.descriptor.id == "discovered.com.example.acme.browser" }?
                .historyWriteAdapter
        )

        let firefox = try XCTUnwrap(discoveries.first {
            $0.coverage.browser.id == "discovered.com.example.acme.fox"
        })
        XCTAssertEqual(firefox.coverage.browser.engine, .firefox)
        XCTAssertEqual(firefox.profiles.map(\.historyDatabaseURL.path), [firefoxHistory.path])
        XCTAssertNil(
            registry.allProviders(
                homeDirectory: home,
                installedApplications: applications
            ).first { $0.descriptor.id == "discovered.com.example.acme.fox" }?
                .historyWriteAdapter
        )

        XCTAssertEqual(
            BrowserPrivacyProviderRegistry.defaultProviders
                .first { $0.descriptor.id == "chrome" }?
                .historyWriteAdapter,
            .chromiumProduction
        )
    }

    func testUnknownBrowserWithoutSQLiteHistoryIsNotPromoted() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try makeApplication(
            in: home,
            bundleIdentifier: "com.example.lookalike",
            displayName: "Lookalike Browser"
        )
        let history = home.appendingPathComponent(
            "Library/Application Support/Lookalike Browser/Default/History"
        )
        try FileManager.default.createDirectory(
            at: history.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: history.path, contents: Data()))

        let applications = await BrowserPrivacyApplicationLocator
            .discoverWithSigningIdentity(
                homeDirectory: home,
                identityReader: FixedSigningIdentityReader(identity: nil)
            )
        let discoveries = BrowserPrivacyProviderRegistry().discover(
            homeDirectory: home,
            installedApplications: applications
        )
        XCTAssertFalse(discoveries.contains {
            $0.coverage.browser.id == "discovered.com.example.lookalike"
        })
    }

    func testUnsignedOrMismatchedUnknownBrowserCannotClaimAProfile() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let unsigned = try makeApplication(
            in: home,
            bundleIdentifier: "com.vendor.unsigned-browser",
            displayName: "Unsigned Browser"
        )
        let mismatched = try makeApplication(
            in: home,
            bundleIdentifier: "com.vendor.mismatched-browser",
            displayName: "Mismatched Browser"
        )
        let signedNonHandler = try makeApplication(
            in: home,
            bundleIdentifier: "com.vendor.signed-non-handler",
            displayName: "Signed Non Handler",
            declaresWebHandler: false
        )
        let vendorRoot = home.appendingPathComponent(
            "Library/Application Support/vendor/Default/History"
        )
        try makeSQLiteHeaderFile(at: vendorRoot)
        let unsignedRoot = home.appendingPathComponent(
            "Library/Application Support/Unsigned Browser/Default/History"
        )
        try makeSQLiteHeaderFile(at: unsignedRoot)
        let mismatchedRoot = home.appendingPathComponent(
            "Library/Application Support/Mismatched Browser/Default/History"
        )
        try makeSQLiteHeaderFile(at: mismatchedRoot)
        let signedNonHandlerRoot = home.appendingPathComponent(
            "Library/Application Support/Signed Non Handler/Default/History"
        )
        try makeSQLiteHeaderFile(at: signedNonHandlerRoot)

        let applications = await BrowserPrivacyApplicationLocator
            .discoverWithSigningIdentity(
                homeDirectory: home,
                identityReader: MapSigningIdentityReader(identities: [
                    mismatched.path: StartupApplicationSigningIdentity(
                        teamIdentifier: "TEAM-VENDOR",
                        codeSigningIdentifier: "com.vendor.other-app",
                        designatedRequirement: nil
                    ),
                    signedNonHandler.path: StartupApplicationSigningIdentity(
                        teamIdentifier: "TEAM-VENDOR",
                        codeSigningIdentifier: "com.vendor.signed-non-handler",
                        designatedRequirement: nil
                    )
                ])
            )
        let discoveries = BrowserPrivacyProviderRegistry().discover(
            homeDirectory: home,
            installedApplications: applications
        )
        XCTAssertFalse(discoveries.contains {
            $0.coverage.browser.id == "discovered.com.vendor.unsigned.browser"
        })
        XCTAssertFalse(discoveries.contains {
            $0.coverage.browser.id == "discovered.com.vendor.mismatched.browser"
        })
        XCTAssertFalse(discoveries.contains {
            $0.coverage.browser.id == "discovered.com.vendor.signed.non.handler"
        })
        XCTAssertFalse(discoveries.contains {
            $0.profiles.contains { $0.historyDatabaseURL.path == vendorRoot.path }
        })

        _ = unsigned
    }
}

private struct FixedSigningIdentityReader: StartupApplicationSigningIdentityReading {
    let identityValue: StartupApplicationSigningIdentity?

    init(identity: StartupApplicationSigningIdentity?) {
        identityValue = identity
    }

    func identity(at _: URL, executableURL _: URL?) async -> StartupApplicationSigningIdentity? {
        identityValue
    }
}

private struct MapSigningIdentityReader: StartupApplicationSigningIdentityReading {
    let identities: [String: StartupApplicationSigningIdentity]

    func identity(at bundleURL: URL, executableURL _: URL?) async -> StartupApplicationSigningIdentity? {
        identities[bundleURL.path]
    }
}

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserPrivacyApplicationDiscovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@discardableResult
private func makeApplication(
    in home: URL,
    bundleIdentifier: String,
    displayName: String,
    declaresWebHandler: Bool = true
) throws -> URL {
    let app = home.appendingPathComponent("Applications/\(displayName).app")
    let executable = app.appendingPathComponent("Contents/MacOS/Browser")
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    var info: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleName": displayName,
        "CFBundleDisplayName": displayName,
        "CFBundleExecutable": "Browser",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
    ]
    if declaresWebHandler {
        info["CFBundleURLTypes"] = [[
            "CFBundleURLSchemes": ["http", "https"],
        ]]
    }
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    XCTAssertTrue(FileManager.default.createFile(
        atPath: app.appendingPathComponent("Contents/Info.plist").path,
        contents: infoData
    ))
    XCTAssertTrue(FileManager.default.createFile(
        atPath: executable.path,
        contents: Data("fixture".utf8)
    ))
    return app.standardizedFileURL
}

private func makeSQLiteHeaderFile(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    XCTAssertTrue(FileManager.default.createFile(
        atPath: url.path,
        contents: Data("SQLite format 3\0".utf8) + Data(repeating: 0, count: 64)
    ))
}

private func makeSQLiteDatabase(at url: URL, statements: [String]) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    var database: OpaquePointer?
    XCTAssertEqual(
        sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ),
        SQLITE_OK
    )
    guard let database else { return }
    defer { sqlite3_close_v2(database) }
    for statement in statements {
        XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, nil), SQLITE_OK)
    }
}
