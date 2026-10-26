import Foundation
import XCTest
@testable import StorageCleanerMac

/// D225 补: the Chinese interface names the two path actions one way, as
/// most of the app already did: “复制路径” and “在访达中显示” (the English
/// “Copy Path”, “Show in Finder” and “Reveal in Finder” stay). Comments are
/// skipped; every string in Sources counts.
final class PathActionWordingD225Tests: XCTestCase {
    func testTheChineseInterfaceSaysCopyPathAndShowInFinderOneWay() throws {
        var found: [String] = []
        var copyPath = 0
        var showInFinder = 0
        for (path, text) in try SwiftSourceScanning.sources() {
            let literals = SwiftSourceScanning.compactKeepingLiterals(text)
            for retired in ["拷贝路径", "在 Finder 中显示"] where literals.contains(retired) {
                found.append("\(path): \(retired)")
            }
            copyPath += SwiftSourceScanning.occurrences(of: "复制路径", in: literals)
            showInFinder += SwiftSourceScanning.occurrences(of: "在访达中显示", in: literals)
        }
        XCTAssertEqual(found.sorted(), [], "Say “复制路径” and “在访达中显示”")
        XCTAssertGreaterThan(copyPath, 0, "the scan reads the interface text")
        XCTAssertGreaterThan(showInFinder, 0, "the scan reads the interface text")
    }
}
