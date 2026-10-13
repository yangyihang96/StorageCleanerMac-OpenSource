import Foundation
import XCTest
@testable import StorageCleanerMac

final class FileAnalysisApplicationBundleTraversalTests: XCTestCase {
    /// 整体汇总的应用内部不读嵌套包；普通 .app 数据目录内部仍需探测。
    /// 单线程与并行模式均记录真实调用，比较最终索引以锁定汇总行为。
    func testNestedAppsAreNotProbedInsideAnApplicationInAnyWalkMode() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let outers = ["Outer.app", "Folders/Deep/Other.app"]
        for relative in outers {
            let contents = fixture.url(relative + "/Contents")
            try manager.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try Data([1]).write(to: contents.appendingPathComponent("MacOS/Tool"))
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Tool"], format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let nested = contents.appendingPathComponent("PlugIns/Nested.app/Contents")
            try manager.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("not a property list".utf8).write(to: nested.appendingPathComponent("Info.plist"))
        }
        let dataFolder = fixture.url("Data.app")
        try manager.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        try Data([1]).write(to: dataFolder.appendingPathComponent("store.sqlite"))
        let inner = dataFolder.appendingPathComponent("Inner.app/Contents")
        try manager.createDirectory(at: inner.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try Data([1]).write(to: inner.appendingPathComponent("MacOS/Inner"))
        try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
            .write(to: inner.appendingPathComponent("Info.plist"))
        let scanner = DiskScanner(excludedPaths: [])
        var reference: StorageMapAnalysisResult?
        for concurrency in [1, 4, 8] {
            let calls = ApplicationBundleProbeCalls()
            var options = DiskScanner.StorageMapAnalysisOptions(concurrency: concurrency, ubiquityLookup: .whereNeeded)
            options.applicationBundleProbe = { path in
                calls.record(path)
                return FileAnalysisApplicationBundleProbe.isApplication(atPath: path)
            }
            let result = try scanner.storageMapAnalysis(target: fixture.target, options: options)
            let expected = Set((outers + ["Tool.app", "Data.app", "Data.app/Inner.app"]).map { fixture.url($0).path })
            XCTAssertEqual(Set(calls.paths), expected, "并发数 \(concurrency)：只探测可影响分类的包")
            XCTAssertEqual(calls.paths.count, expected.count, "每个需探测的包只读一次")
            for relative in outers {
                let url = fixture.url(relative)
                let row = try XCTUnwrap(try scanner.storageMapSnapshot(at: url.deletingLastPathComponent().path,
                    using: result.index).entries.first { $0.path == url.path })
                XCTAssertEqual(row.contentCategory, .application)
                XCTAssertFalse(row.canDescend)
                XCTAssertGreaterThan(row.sizeBytes, 0)
            }
            if let reference {
                XCTAssertEqual(result.index, reference.index)
                XCTAssertEqual(result.rootSnapshot, reference.rootSnapshot)
                XCTAssertEqual(result.inspectedItemCount, reference.inspectedItemCount)
            } else {
                reference = result
            }
        }
    }
}

private final class ApplicationBundleProbeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var paths: [String] { lock.withLock { recorded } }
    func record(_ path: String) { lock.withLock { recorded.append(path) } }
}
