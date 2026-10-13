import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class FileAnalysisApplicationBundleSpecialInfoTests: XCTestCase {
    func testNonRegularInfoPlistsUseBundleNameWithoutOpeningOrBlocking() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        for isFIFO in [false, true] {
            let name = isFIFO ? "FIFO" : "Directory"
            let bundle = try makeBundle(name, isFIFO: isFIFO, in: fixture)
            var attemptedOpen = false
            let missingStart = ContinuousClock.now
            XCTAssertFalse(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path,
                beforeOpeningInfoPlist: { attemptedOpen = true }), "没有普通可执行文件仍按文件夹处理")
            XCTAssertLessThan(ContinuousClock.now - missingStart, .seconds(1))
            XCTAssertFalse(attemptedOpen, "非普通 plist 不得进入 open 分支")
            try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: bundle.appendingPathComponent("Contents/MacOS/" + name))
            let foundStart = ContinuousClock.now
            XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path,
                beforeOpeningInfoPlist: { attemptedOpen = true }), name)
            XCTAssertLessThan(ContinuousClock.now - foundStart, .seconds(1), "不能等待 FIFO 的写端")
            XCTAssertFalse(attemptedOpen, "找到包名可执行文件时也不能打开非普通 plist")
        }
    }

    func testNonRegularInfoPlistsStayBlockedWhenExecutableLookupIsUncertain() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        for isFIFO in [false, true] {
            let name = isFIFO ? "LinkedFIFO" : "LinkedDirectory"
            let bundle = try makeBundle(name, isFIFO: isFIFO, in: fixture)
            try manager.removeItem(at: bundle.appendingPathComponent("Contents/MacOS"))
            try manager.createSymbolicLink(at: bundle.appendingPathComponent("Contents/MacOS"),
                                           withDestinationURL: fixture.url("missing-target"))
            var attemptedOpen = false
            XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path,
                beforeOpeningInfoPlist: { attemptedOpen = true }), "无法确定候选位置时保守挡住")
            XCTAssertFalse(attemptedOpen)
        }
    }

    private func makeBundle(_ name: String, isFIFO: Bool, in fixture: TrashFixture) throws -> URL {
        let bundle = fixture.url(name + ".app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        if isFIFO {
            let result = mkfifo(plist.path, 0o600)
            XCTAssertEqual(result, 0)
            guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else {
            try FileManager.default.createDirectory(at: plist, withIntermediateDirectories: true)
        }
        return bundle
    }
}
