import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// No real sharedfilelist folder, Trash, process table, signal or journal.
/// Native moves are injected as renames inside this owned fixture. Normal
/// runs use the standard hidden-home operation root. A sandbox runner may
/// put TMPDIR inside its workspace to keep every fixture there as well.
struct RecentItemsTestFixture: Sendable {
    let root: URL
    let scanner: RecentItemsScanner
    let journal: CleanupReportJournal
    let trash: URL
    let events = RecentItemsTestEvents()

    init(_ test: XCTestCase) throws {
        root = PathSafety.isLexicallyInsideHome(FileManager.default.temporaryDirectory.path)
            ? TestFileSystem.uniqueRoot("RecentItems")
            : TestFileSystem.uniqueOperationRoot("recent-items")
        TestFileSystem.registerCleanup(of: root, for: test)
        let listRoot = root.appendingPathComponent("home/Library/Application Support/com.apple.sharedfilelist")
        scanner = RecentItemsScanner(rootURL: listRoot)
        journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts", isDirectory: true))
        trash = root.appendingPathComponent("fixture-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: listRoot.appendingPathComponent(RecentItemsScanner.applicationDirectory), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ name: String = "com.apple.LSSharedFileList.RecentDocuments.sfl4", count: Int = 2,
               app: Bool = false) throws -> URL {
        let parent = app ? scanner.rootURL.appendingPathComponent(RecentItemsScanner.applicationDirectory) : scanner.rootURL
        let url = parent.appendingPathComponent(name)
        try Self.archive(count: count).write(to: url)
        return url
    }

    var environment: RecentItemsCleanupEnvironment {
        RecentItemsCleanupEnvironment(scanner: scanner, journal: journal,
            moveToTrash: { source in
                events.append("move:\(source.lastPathComponent)")
                let target = trash.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: target)
                return target
            }, processController: .init(processes: { events.append("processes"); return [] },
                                        lookup: { _ in XCTFail("No lookup expected"); return nil },
                                        signal: { _, _ in XCTFail("No native signal permitted"); return -1 }),
            waitForWriteback: { events.append("wait") })
    }

    static func archive(count: Int) throws -> Data {
        // A real keyed archive exercises binary UID references. The decoder
        // below deliberately traps: the product must only read the plist.
        let items = (0..<count).map { _ in RecentItemsFixtureSFLListItem() }
        return try NSKeyedArchiver.archivedData(withRootObject: items, requiringSecureCoding: false)
    }

    func clean(_ selected: [RecentItemsList]? = nil, confirmed: Bool = true,
               environment: RecentItemsCleanupEnvironment? = nil) async throws -> RecentItemsCleanupResult? {
        try await RecentItemsCleanupService.clean(selected: selected ?? scanner.scan().lists, confirmed: confirmed,
                                                  environment: environment ?? self.environment, coordinator: HeavyWorkCoordinator())
    }
}

@objc(RecentItemsFixtureSFLListItem)
final class RecentItemsFixtureSFLListItem: NSObject, NSCoding {
    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError("D188 must never unarchive a list item") }
    func encode(with coder: NSCoder) { coder.encode(Data("opaque-bookmark-fixture".utf8), forKey: "Bookmark") }
}

final class RecentItemsTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
