import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppStoreCatalogResolverTests: XCTestCase {
    func testLookupUsesExactBundleIdentifierMacSoftwareAndStorefront() async throws {
        let client = FixtureAppStoreCatalogHTTPClient(
            data: catalogData(results: [catalogResult()])
        )
        let resolver = AppStoreCatalogResolver(client: client, timeout: 7)

        let resolution = try await resolver.resolve(
            bundleIdentifier: "com.example.store",
            storefront: "AU"
        )

        guard case let .matched(entry) = resolution else {
            return XCTFail("Expected an exact catalog match")
        }
        XCTAssertEqual(entry.bundleIdentifier, "com.example.store")
        XCTAssertEqual(entry.version, ApplicationVersion(marketing: "2.0"))
        XCTAssertEqual(entry.productURL.absoluteString, "https://apps.apple.com/au/app/example/id123")
        XCTAssertEqual(entry.downloadSize, 123_456)
        XCTAssertEqual(entry.averageUserRating, 4.2)
        XCTAssertEqual(entry.userRatingCount, 120)

        let recordedRequest = await client.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.timeoutInterval, 7)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "itunes.apple.com")
        XCTAssertEqual(components.path, "/lookup")
        XCTAssertEqual(query["bundleId"] ?? nil, "com.example.store")
        XCTAssertEqual(query["entity"] ?? nil, "macSoftware")
        XCTAssertEqual(query["country"] ?? nil, "au")
    }

    func testParserDoesNotFuzzyMatchNameWrongBundleOrWrongPlatform() throws {
        let data = catalogData(results: [
            catalogResult(bundleIdentifier: "com.example.lookalike", trackName: "Example"),
            catalogResult(bundleIdentifier: "com.example.store", kind: "software", trackName: "Example"),
            catalogResult(bundleIdentifier: "com.example.store", wrapperType: "collection", trackName: "Example"),
        ])

        XCTAssertEqual(
            try AppStoreCatalogResolver.parse(data, expectedBundleIdentifier: "com.example.store"),
            .notFound
        )
    }

    func testParserReturnsAmbiguousForMultipleExactRecords() throws {
        let data = catalogData(results: [catalogResult(), catalogResult(version: "2.1")])

        XCTAssertEqual(
            try AppStoreCatalogResolver.parse(data, expectedBundleIdentifier: "com.example.store"),
            .ambiguous
        )
    }

    func testParserRejectsNonHTTPSOrNonAppleProductURL() throws {
        for url in [
            "http://apps.apple.com/au/app/example/id123",
            "https://apps.apple.com.evil.example/au/app/example/id123",
            "https://user@apps.apple.com/au/app/example/id123",
        ] {
            XCTAssertThrowsError(try AppStoreCatalogResolver.parse(
                catalogData(results: [catalogResult(productURL: url)]),
                expectedBundleIdentifier: "com.example.store"
            )) { error in
                XCTAssertEqual(error as? AppStoreCatalogError, .invalidProductURL)
            }
        }
    }

    func testStorefrontFallsBackToUSForInvalidRegion() {
        XCTAssertEqual(AppStoreCatalogResolver.normalizedStorefront("AU"), "au")
        XCTAssertEqual(AppStoreCatalogResolver.normalizedStorefront("419"), "us")
        XCTAssertEqual(AppStoreCatalogResolver.normalizedStorefront(nil), "us")
    }

    func testProviderReportsNewerCatalogVersionButRemainsAppStoreManaged() async throws {
        let entry = AppStoreCatalogEntry(
            bundleIdentifier: "com.example.app",
            version: ApplicationVersion(marketing: "2.0"),
            productURL: URL(string: "https://apps.apple.com/au/app/example/id123")!,
            sellerName: "Example Developer",
            releaseDate: nil,
            releaseNotes: "Notes",
            downloadSize: 123
        )
        let provider = MacAppStoreProvider(
            receiptVerifier: AlwaysValidReceiptVerifier(),
            catalogResolver: FixedCatalogResolver(result: .matched(entry)),
            storefront: "au"
        )
        let application = app(version: "1.0")

        let result = try await provider.checkForUpdate(application)

        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertEqual(result.availableVersion, ApplicationVersion(marketing: "2.0"))
        XCTAssertEqual(result.appStoreProductURL, entry.productURL)
        let info = try await provider.inspect(application)
        XCTAssertFalse(info.canAutomaticallyUpdate)
        XCTAssertTrue(info.requiresUserInteraction)
    }

    func testProviderReportsUpToDateWhenInstalledVersionIsNotOlder() async throws {
        let entry = AppStoreCatalogEntry(
            bundleIdentifier: "com.example.app",
            version: ApplicationVersion(marketing: "2.0"),
            productURL: URL(string: "https://itunes.apple.com/app/id123")!,
            sellerName: nil,
            releaseDate: nil,
            releaseNotes: nil,
            downloadSize: nil
        )
        let provider = MacAppStoreProvider(
            receiptVerifier: AlwaysValidReceiptVerifier(),
            catalogResolver: FixedCatalogResolver(result: .matched(entry))
        )

        let result = try await provider.checkForUpdate(app(version: "2.0"))

        XCTAssertEqual(result.status, .upToDate)
        XCTAssertEqual(result.appStoreProductURL, entry.productURL)
        XCTAssertNil(result.warning)
    }

    func testRegistryPersistsExactProductURLAndNeverMarksAutomatic() async {
        let productURL = URL(string: "https://apps.apple.com/au/app/example/id123")!
        let entry = AppStoreCatalogEntry(
            bundleIdentifier: "com.example.app",
            version: ApplicationVersion(marketing: "2.0"),
            productURL: productURL,
            sellerName: nil,
            releaseDate: nil,
            releaseNotes: nil,
            downloadSize: nil
        )
        let registry = ApplicationUpdateProviderRegistry(providers: [
            MacAppStoreProvider(
                receiptVerifier: AlwaysValidReceiptVerifier(),
                catalogResolver: FixedCatalogResolver(result: .matched(entry))
            ),
            ManualUpdateProvider(),
        ])

        let classified = await registry.classify(app(version: "1.0"))

        XCTAssertEqual(classified.appStoreProductURL, productURL)
        XCTAssertEqual(classified.versionCheckState, .updateAvailable)
        XCTAssertEqual(classified.updateCapability, .appStoreManaged)
        XCTAssertFalse(classified.canAutomaticallyUpdate)
    }

    func testProviderPropagatesCancellation() async {
        let provider = MacAppStoreProvider(
            receiptVerifier: AlwaysValidReceiptVerifier(),
            catalogResolver: CancellingCatalogResolver()
        )

        do {
            _ = try await provider.checkForUpdate(app(version: "1.0"))
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not become a catalog failure.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTTPFailureTripsCooldownAndSecondLookupSkipsNetwork() async throws {
        let client = FixtureAppStoreCatalogHTTPClient(
            data: catalogData(results: []),
            statusCode: 503
        )
        let resolver = AppStoreCatalogResolver(
            client: client,
            timeout: 8,
            cooldown: 60
        )

        do {
            _ = try await resolver.resolve(
                bundleIdentifier: "com.example.store",
                storefront: "au"
            )
            XCTFail("Expected the service failure")
        } catch {
            XCTAssertEqual(error as? AppStoreCatalogError, .unexpectedStatus(503))
        }

        do {
            _ = try await resolver.resolve(
                bundleIdentifier: "com.example.other",
                storefront: "au"
            )
            XCTFail("Expected the shared cooldown")
        } catch {
            XCTAssertEqual(error as? AppStoreCatalogError, .temporarilyUnavailable)
        }
        let failedRequestCount = await client.requestCount()
        XCTAssertEqual(failedRequestCount, 1)
    }

    func testCancellationDoesNotTripCooldown() async throws {
        let client = CancellationThenSuccessCatalogClient(
            successData: catalogData(results: [catalogResult()])
        )
        let resolver = AppStoreCatalogResolver(client: client, cooldown: 60)

        do {
            _ = try await resolver.resolve(
                bundleIdentifier: "com.example.store",
                storefront: "au"
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation is caller intent, not service availability.
        }

        let result = try await resolver.resolve(
            bundleIdentifier: "com.example.store",
            storefront: "au"
        )
        guard case .matched = result else {
            return XCTFail("Expected the second request to reach the service")
        }
        let cancellationRequestCount = await client.requestCount()
        XCTAssertEqual(cancellationRequestCount, 2)
    }

    func testAppStoreProductURLValidationRejectsLookalikeHost() {
        var application = app(version: "1.0")
        application.updateProvider = .macAppStore
        application.appStoreProductURL = URL(string: "https://apps.apple.com.evil.example/app/id123")
        XCTAssertNil(AppUpdateService.validatedAppStoreProductURL(for: application))

        application.appStoreProductURL = URL(string: "https://apps.apple.com/au/app/example/id123")
        XCTAssertEqual(
            AppUpdateService.validatedAppStoreProductURL(for: application)?.host,
            "apps.apple.com"
        )
    }

    private func app(version: String) -> InstalledApplication {
        AppUpdateTestFixtures.application(
            bundleIdentifier: "com.example.app",
            version: version,
            provider: .macAppStore,
            sourceEvidence: [
                "app-store-receipt",
                "verified-app-store-receipt",
                "valid-code-signature",
                "signed-bundle-identity",
            ]
        )
    }

    private func catalogData(results: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "resultCount": results.count,
            "results": results,
        ])
    }

    private func catalogResult(
        bundleIdentifier: String = "com.example.store",
        version: String = "2.0",
        productURL: String = "https://apps.apple.com/au/app/example/id123",
        wrapperType: String = "software",
        kind: String = "mac-software",
        trackName: String = "Example",
        averageUserRating: Double = 4.2,
        userRatingCount: Int = 120
    ) -> [String: Any] {
        [
            "bundleId": bundleIdentifier,
            "version": version,
            "trackViewUrl": productURL,
            "wrapperType": wrapperType,
            "kind": kind,
            "trackName": trackName,
            "sellerName": "Example Developer",
            "currentVersionReleaseDate": "2026-07-19T10:00:00Z",
            "releaseNotes": "Notes",
            "fileSizeBytes": "123456",
            "averageUserRating": averageUserRating,
            "userRatingCount": userRatingCount,
        ]
    }
}

private actor FixtureAppStoreCatalogHTTPClient: AppStoreCatalogHTTPClient {
    private let responseData: Data
    private let statusCode: Int
    private var request: URLRequest?
    private var count = 0

    init(data: Data, statusCode: Int = 200) {
        responseData = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        count += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (responseData, response)
    }

    func lastRequest() -> URLRequest? { request }
    func requestCount() -> Int { count }
}

private actor CancellationThenSuccessCatalogClient: AppStoreCatalogHTTPClient {
    private let successData: Data
    private var count = 0

    init(successData: Data) {
        self.successData = successData
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        guard count > 1 else { throw CancellationError() }
        return (
            successData,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    func requestCount() -> Int { count }
}

private struct FixedCatalogResolver: AppStoreCatalogResolving {
    let result: AppStoreCatalogResolution

    func resolve(
        bundleIdentifier: String,
        storefront: String
    ) async throws -> AppStoreCatalogResolution {
        result
    }
}

private struct CancellingCatalogResolver: AppStoreCatalogResolving {
    func resolve(
        bundleIdentifier: String,
        storefront: String
    ) async throws -> AppStoreCatalogResolution {
        throw CancellationError()
    }
}

private struct AlwaysValidReceiptVerifier: MacAppStoreReceiptVerifying {
    func verifyReceipt(at applicationURL: URL) async -> Bool { true }
}
