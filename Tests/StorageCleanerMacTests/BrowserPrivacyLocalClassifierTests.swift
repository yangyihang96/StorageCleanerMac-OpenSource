import Foundation
import XCTest
@testable import StorageCleanerMac

final class BrowserPrivacyLocalClassifierTests: XCTestCase {
    func testBundledHighConfidenceRulesAreVersionedAndContainNoPlaceholderHost() {
        let rules = BrowserPrivacyLocalRuleSet.bundled

        XCTAssertEqual(rules.version, 1)
        XCTAssertEqual(
            rules.highConfidenceAdultTerminalLabels,
            ["adult", "porn", "sex", "xxx"]
        )
        XCTAssertFalse(
            rules.highConfidenceAdultTerminalLabels.contains { $0.contains("invalid") }
        )

        let classifier = BrowserPrivacyLocalClassifier()
        for suffix in rules.highConfidenceAdultTerminalLabels {
            XCTAssertEqual(
                classifier.classify(url: nil, title: nil, domain: "example.\(suffix)"),
                .init(category: .adult, confidence: .high),
                suffix
            )
        }
    }

    func testHighConfidenceSuffixNormalizesCaseTrailingDotAndIDNA() {
        let classifier = BrowserPrivacyLocalClassifier()

        XCTAssertEqual(
            classifier.classify(url: nil, title: nil, domain: "PRIVATE.EXAMPLE.XXX."),
            .init(category: .adult, confidence: .high)
        )
        XCTAssertEqual(
            classifier.classify(url: nil, title: nil, domain: "BÜCHER.XXX"),
            classifier.classify(url: nil, title: nil, domain: "xn--bcher-kva.xxx")
        )
        XCTAssertEqual(
            classifier.classify(url: nil, title: nil, domain: "xn--bcher-kva.xxx"),
            .init(category: .adult, confidence: .high)
        )
    }

    func testHighConfidenceSuffixRequiresAnExactTerminalDNSLabel() {
        let classifier = BrowserPrivacyLocalClassifier()
        let lookalikes = [
            "example.xxx.evil.test",
            "example.notxxx",
            "xxx.example.com",
            "example.ххх",
        ]

        for host in lookalikes {
            XCTAssertEqual(
                classifier.classify(url: nil, title: nil, domain: host),
                .init(category: .other, confidence: .low),
                host
            )
        }
    }

    func testMalformedAndMissingHostsFailClosedWhileValidUnmatchedHostIsOther() {
        let classifier = BrowserPrivacyLocalClassifier()

        for host in [
            "", "xxx", "bad..xxx", "bad.xxx..", "-bad.xxx", "bad-.xxx",
            "example.xxx/path",
        ] {
            XCTAssertEqual(
                classifier.classify(url: nil, title: nil, domain: host),
                .init(category: .unknown, confidence: .unavailable),
                host
            )
        }
        XCTAssertEqual(
            classifier.classify(
                url: "https://ordinary.example/path",
                title: "Unclassified page",
                domain: nil
            ),
            .init(category: .unknown, confidence: .unavailable)
        )
        XCTAssertEqual(
            classifier.classify(url: nil, title: nil, domain: "ordinary.example"),
            .init(category: .other, confidence: .low)
        )
    }

    func testDefaultConstructionKeepsLegacyKeywordConfidenceBelowAutomaticSelection() {
        let classifier = BrowserPrivacyLocalClassifier()

        XCTAssertEqual(
            classifier.classify(
                url: "https://review.example/nsfw",
                title: "Review",
                domain: "review.example"
            ),
            .init(category: .adult, confidence: .low)
        )
        XCTAssertEqual(
            classifier.classify(
                url: "https://review.example/nsfw",
                title: "Adult content and explicit video",
                domain: "review.example"
            ),
            .init(category: .adult, confidence: .medium)
        )
    }

    func testProductionClassifierContainsNoPlaceholderOrNetworkPath() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/BrowserPrivacy/Classification/BrowserPrivacyLocalClassifier.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(".invalid"))
        XCTAssertFalse(source.contains("URLSession"))
        XCTAssertFalse(source.contains("URLRequest"))
        XCTAssertFalse(source.contains("NSWorkspace"))
        XCTAssertFalse(source.contains("Data(contentsOf:"))
    }
}
