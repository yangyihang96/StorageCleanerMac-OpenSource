import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppleSiliconCatalogTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Benchmark")
    }
    private func loaded() -> AppleSiliconCatalogLoader.Loaded {
        AppleSiliconCatalogLoader.load(catalogURL: resources.appendingPathComponent("AppleSiliconCatalog.json"),
            manifestURL: resources.appendingPathComponent("AppleSiliconCatalog.manifest.json"))
    }
    // Independent expectation matrix; never generate expected topology from the catalog being tested.
    private let configurations: [(String, Int, Int, Int, Int)] = [
        ("m1-8c-7g",0,4,4,7), ("m1-8c-8g",0,4,4,8),
        ("m1-pro-8c-14g",0,6,2,14), ("m1-pro-10c-14g",0,8,2,14), ("m1-pro-10c-16g",0,8,2,16),
        ("m1-max-10c-24g",0,8,2,24), ("m1-max-10c-32g",0,8,2,32),
        ("m1-ultra-20c-48g",0,16,4,48), ("m1-ultra-20c-64g",0,16,4,64),
        ("m2-8c-8g",0,4,4,8), ("m2-8c-10g",0,4,4,10),
        ("m2-pro-10c-16g",0,6,4,16), ("m2-pro-12c-19g",0,8,4,19),
        ("m2-max-12c-30g",0,8,4,30), ("m2-max-12c-38g",0,8,4,38),
        ("m2-ultra-24c-60g",0,16,8,60), ("m2-ultra-24c-76g",0,16,8,76),
        ("m3-8c-8g",0,4,4,8), ("m3-8c-10g",0,4,4,10),
        ("m3-pro-11c-14g",0,5,6,14), ("m3-pro-12c-18g",0,6,6,18),
        ("m3-max-14c-30g",0,10,4,30), ("m3-max-16c-40g",0,12,4,40),
        ("m3-ultra-28c-60g",0,20,8,60), ("m3-ultra-32c-80g",0,24,8,80),
        ("m4-8c-8g",0,4,4,8), ("m4-10c-10g",0,4,6,10),
        ("m4-pro-12c-16g",0,8,4,16), ("m4-pro-14c-20g",0,10,4,20),
        ("m4-max-14c-32g",0,10,4,32), ("m4-max-16c-40g",0,12,4,40),
        ("m5-10c-8g",4,0,6,8), ("m5-10c-10g",4,0,6,10),
        ("m5-pro-15c-16g",5,10,0,16), ("m5-pro-18c-20g",6,12,0,20),
        ("m5-max-18c-32g",6,12,0,32), ("m5-max-18c-40g",6,12,0,40),
        ("m5-ultra-30c-64g",10,20,0,64), ("m5-ultra-36c-80g",12,24,0,80)
    ]
    private func evidence(brand: String, superCount: Int = 6, performance: Int = 12, efficiency: Int = 0,
                          gpu: Int? = 20, metal: String? = nil, native: Bool = true, translated: Bool? = false,
                          reverse: Bool = false) -> AppleSiliconHardwareEvidence {
        var pairs = [("Super", superCount), ("Performance", performance), ("Efficiency", efficiency)].filter { $0.1 > 0 }
        if reverse { pairs.reverse() }
        return .init(capturedAt: Date(timeIntervalSinceReferenceDate: 1), nativeARM64: native, translated: translated,
            brandString: brand, modelIdentifier: nil, perfLevelCount: pairs.count,
            perfLevels: pairs.enumerated().map { .init(index: $0.offset, name: $0.element.0,
                physicalCores: $0.element.1, logicalCores: nil) }, physicalCPUCount: superCount + performance + efficiency,
            metalDeviceName: metal, profilerGPUName: nil, profilerGPUCores: gpu,
            physicalMemoryBytes: 48 * 1024 * 1024 * 1024, missingReasons: [])
    }

    func testAll39SKUPositiveEvidenceAndUnknownTopologyRemainsUnverified() throws {
        let table = loaded()
        let catalog = try XCTUnwrap(table.catalog)
        XCTAssertEqual(catalog.chips.flatMap(\.skus).count, 39)
        XCTAssertEqual(configurations.count, 39)
        for (skuID, superCount, performance, efficiency, gpu) in configurations {
            let chipID = skuID.components(separatedBy: "-\(superCount + performance + efficiency)c-").first!
            let brand = "Apple " + chipID.uppercased().replacingOccurrences(of: "-PRO", with: " Pro")
                .replacingOccurrences(of: "-MAX", with: " Max").replacingOccurrences(of: "-ULTRA", with: " Ultra")
            let input = evidence(brand: brand, superCount: superCount, performance: performance, efficiency: efficiency, gpu: gpu, reverse: true)
            let identity = AppleSiliconIdentifier.identify(input, catalog: table)
            XCTAssertEqual(identity.candidateSKUIDs, [skuID], skuID)
            if skuID == "m5-ultra-36c-80g" {
                XCTAssertEqual(identity.identificationStatus, .ambiguous)
                XCTAssertNil(identity.matchedSKU)
                XCTAssertTrue(identity.reasonCodes.contains("skuTopologyUnverified"))
            } else {
                XCTAssertEqual(identity.identificationStatus, .matched, skuID)
                XCTAssertEqual(identity.matchedSKU?.id, skuID)
            }
            XCTAssertTrue(identity.identificationEvidence.perfLevels.allSatisfy { $0.logicalCores == nil })
        }
    }
    func testAdjacentConfigurationsAndBrandConflictNeverGuess() {
        let table = loaded()
        for input in [evidence(brand: "Apple M5 Pro", superCount: 5, performance: 10, gpu: 20),
                      evidence(brand: "Apple M5 Pro", gpu: 16),
                      evidence(brand: "Apple M4 Max", superCount: 0, performance: 10, efficiency: 4, gpu: 40),
                      evidence(brand: "Apple M4 Max", superCount: 0, performance: 12, efficiency: 4, gpu: 32),
                      evidence(brand: "Apple M5 Pro", metal: "Apple M5") , evidence(brand: "Apple M5 Pro", gpu: nil)] {
            XCTAssertEqual(AppleSiliconIdentifier.identify(input, catalog: table).identificationStatus, .ambiguous)
        }
        XCTAssertEqual(AppleSiliconIdentifier.identify(evidence(brand: "Apple M99"), catalog: table).identificationStatus, .unknownAppleSilicon)
        XCTAssertEqual(AppleSiliconIdentifier.identify(evidence(brand: "Intel Core i7", native: false), catalog: table).identificationStatus, .intel)
        XCTAssertEqual(AppleSiliconIdentifier.identify(evidence(brand: "Apple M5 Pro", native: false, translated: true), catalog: table).identificationStatus, .rosetta)
        let unknownTranslation = AppleSiliconIdentifier.identify(evidence(brand: "Apple M5 Pro", translated: nil), catalog: table)
        XCTAssertTrue(unknownTranslation.reasonCodes.contains("translatedUnknown"))
        XCTAssertNil(unknownTranslation.identificationEvidence.translated)
    }
    func testSKUSpecificationsNeverInheritFamilyMaximum() throws {
        let catalog = try XCTUnwrap(loaded().catalog)
        let m4 = try XCTUnwrap(catalog.chips.first { $0.id == "m4-max" })
        XCTAssertEqual(m4.skus.map(\.memoryBandwidthGBps), [410, 546])
        let m5 = try XCTUnwrap(catalog.chips.first { $0.id == "m5-max" })
        XCTAssertEqual(m5.skus.map(\.maxUnifiedMemoryGB), [36, 128])
        let m1 = try XCTUnwrap(catalog.chips.first { $0.id == "m1-pro" })
        XCTAssertNil(m1.skus.first { $0.id == "m1-pro-10c-14g" }?.memoryBandwidthGBps)
        let pro = try XCTUnwrap(catalog.chips.first { $0.id == "m4-pro" }?.skus.first)
        XCTAssertEqual(pro.memoryLimit(for: "MacBook Pro (14-inch, M4 Pro or M4 Max, 2024)"), 48)
        XCTAssertEqual(pro.memoryLimit(for: "Mac mini (2024)"), 64)
        XCTAssertEqual(pro.memoryLimit(for: "Mac16,8"), 48)
        XCTAssertEqual(pro.memoryLimit(for: "Mac16,11"), 64)
        XCTAssertNil(pro.memoryLimit(for: "MacFuture,1"))
    }
    func testMissingCorruptAndHashMismatchSafelyBecomeUnknown() throws {
        XCTAssertTrue(AppleSiliconCatalogLoader.load(catalogURL: nil, manifestURL: nil).specificationsUnknown)
        let bytes = try Data(contentsOf: resources.appendingPathComponent("AppleSiliconCatalog.json"))
        let table = loaded()
        XCTAssertEqual(AppleSiliconCatalogLoader.decode(bytes, manifest: .init(catalogVersion: "bad", sha256: table.sha256!)).reason, "catalogInvalid")
        XCTAssertEqual(AppleSiliconCatalogLoader.decode(bytes, manifest: .init(catalogVersion: "bad", sha256: "bad")).reason, "catalogHashMismatch")
        let corrupt = Data("broken JSON".utf8)
        XCTAssertTrue(AppleSiliconCatalogLoader.decode(corrupt, manifest: .init(catalogVersion: "bad", sha256: MSeriesV11Digest.sha256(corrupt))).specificationsUnknown)
    }
    func testProfilerSelectsAppleGPUInsteadOfLargestExternalDevice() throws {
        let bytes = Data(#"{"SPDisplaysDataType":[{"sppci_model":"AMD External","sppci_cores":"100"},{"sppci_model":"Apple M5 Pro","sppci_cores":"20"}]}"#.utf8)
        XCTAssertEqual(BenchmarkV7HardwareProfileCollector.parseAppleGPU(bytes), .init(name: "Apple M5 Pro", cores: 20))
        XCTAssertNil(BenchmarkV7HardwareProfileCollector.parseAppleGPU(Data(#"{"SPDisplaysDataType":[{"sppci_model":"Apple M5 Pro","sppci_cores":"0"}]}"#.utf8)))
    }

    func testInjectedCollectorReadsAllNamedLevelsAndNeverFillsMissingLogicalReadings() {
        let captured = AppleSiliconHardwareCollector.capture(source: InjectedHardware(), now: Date(timeIntervalSinceReferenceDate: 1))
        XCTAssertEqual(captured.perfLevelCount, 2)
        XCTAssertEqual(captured.perfLevels.map(\.name), ["Performance", "Super"])
        XCTAssertEqual(captured.perfLevels.map(\.physicalCores), [12,6])
        XCTAssertTrue(captured.perfLevels.allSatisfy { $0.logicalCores == nil })
        XCTAssertEqual(captured.profilerGPUCores, 20)
        XCTAssertEqual(captured.physicalMemoryBytes, 48 * 1024 * 1024 * 1024)
        XCTAssertEqual(AppleSiliconIdentifier.identify(captured, catalog: loaded()).matchedSKU?.id, "m5-pro-18c-20g")
    }

    @MainActor
    func testAsyncHardwareCaptureRunsProfilerOffMainThread() async {
        let source = BackgroundHardware()
        let value = await AppleSiliconHardwareCollector.captureAsync(source: source)
        XCTAssertTrue(source.wasOffMainThread)
        XCTAssertEqual(value.profilerGPUCores, 20)
    }

    func testAppBundleResourcePathReadbackWithoutLaunchingAnApplication() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let app = root.appendingPathComponent("CatalogFixture.app")
        let directory = app.appendingPathComponent("Contents/Resources/Benchmark")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier":"local.catalog-fixture", "CFBundlePackageType":"APPL", "CFBundleName":"CatalogFixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        for name in ["AppleSiliconCatalog.json","AppleSiliconCatalog.manifest.json"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: directory.appendingPathComponent(name))
        }
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(AppleSiliconCatalogLoader.load(bundle: bundle).sha256, loaded().sha256)
        XCTAssertNotNil(AppleSiliconCatalogLoader.load(bundle: bundle).catalog)
    }
}

private struct InjectedHardware: AppleSiliconHardwareDataSource {
    var nativeARM64: Bool { true }
    func string(_ key: String) -> String? {
        ["machdep.cpu.brand_string":"Apple M5 Pro", "hw.model":"SyntheticModel",
         "hw.perflevel0.name":"Performance", "hw.perflevel1.name":"Super"][key]
    }
    func integer(_ key: String) -> Int? {
        ["hw.nperflevels":2, "hw.physicalcpu":18, "sysctl.proc_translated":0,
         "hw.perflevel0.physicalcpu":12, "hw.perflevel1.physicalcpu":6][key]
    }
    func memoryBytes() -> UInt64? { 48 * 1024 * 1024 * 1024 }
    func metalDeviceName() -> String? { "Apple M5 Pro" }
    func profilerGPU() -> BenchmarkV7HardwareProfileCollector.AppleGPU? { .init(name: "Apple M5 Pro", cores: 20) }
}

private final class BackgroundHardware: AppleSiliconHardwareDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var background = false
    var wasOffMainThread: Bool { lock.withLock { background } }
    var nativeARM64: Bool { true }
    func string(_ key: String) -> String? { InjectedHardware().string(key) }
    func integer(_ key: String) -> Int? { InjectedHardware().integer(key) }
    func memoryBytes() -> UInt64? { InjectedHardware().memoryBytes() }
    func metalDeviceName() -> String? { "Synthetic" }
    func profilerGPU() -> BenchmarkV7HardwareProfileCollector.AppleGPU? {
        lock.withLock { background = !Thread.isMainThread }
        return .init(name: "Apple M5 Pro", cores: 20)
    }
}
