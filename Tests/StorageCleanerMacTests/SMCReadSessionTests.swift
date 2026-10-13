import AppKit
import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// No real SMC connection, workspace notification center or preferences.
/// All work counts refer to injected driver calls, not timing approximations.
final class SMCReadSessionTests: XCTestCase {
    func testProductionDefaultsRouteAllSMCConsumersToSharedSession() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fan = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Services/SMCFanSpeedService.swift"), encoding: .utf8)
        let power = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Services/SMCPowerTelemetryService.swift"), encoding: .utf8)
        let session = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Services/SMCReadSession.swift"), encoding: .utf8)
        for method in ["currentFanReadings", "currentHardwareReadings", "currentChipTemperatureCelsius"] {
            XCTAssertTrue(fan.contains("static func \(method)(connection: SMCReadSession = .shared"))
        }
        for method in ["currentTelemetry", "currentBatteryTelemetry"] {
            XCTAssertTrue(power.contains("static func \(method)(connection: SMCReadSession = .shared"))
        }
        XCTAssertTrue(session.contains("static let shared = SMCReadSession("))
        XCTAssertFalse(fan.contains("guard let connection = SMCConnection()"))
        XCTAssertFalse(power.contains("SMCConnection()"))
    }

    func testStableMetadataAndConnectionAreReusedButBytesStayFresh() {
        let driver = CountingSMCReadDriver()
        driver.setKey("PSTR", type: "flt ", bytes: smcFloatBytes(12))
        driver.setReadResults("PSTR", [.success(smcFloatBytes(12)), .success(smcFloatBytes(18))])
        let session = SMCReadSession(driver: driver, platform: .appleSilicon)
        defer { withExtendedLifetime(session) {} }

        XCTAssertEqual(session.readRaw("PSTR"), .present(dataType: "flt ", bytes: smcFloatBytes(12)))
        XCTAssertEqual(session.readRaw("PSTR"), .present(dataType: "flt ", bytes: smcFloatBytes(18)))
        XCTAssertEqual(driver.counts.opens, 1, "two samples previously opened twice")
        XCTAssertEqual(driver.counts.closes, 0)
        XCTAssertEqual(driver.counts.keyInfo["PSTR"], 1, "one description for two live samples")
        XCTAssertEqual(driver.counts.bytes["PSTR"], 2, "dynamic reads are never removed")
    }

    func testSessionReleaseClosesTheRetainedConnection() {
        let driver = CountingSMCReadDriver()
        do {
            let session = SMCReadSession(driver: driver, platform: .intel)
            _ = session.readRaw("NONE")
            withExtendedLifetime(session) {}
        }
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertEqual(driver.counts.closes, 1)
    }

    func testFanChipPowerAndBatteryProvidersShareOneSessionWithFreshValues() throws {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        driver.setKey("F0Ac", type: "flt ", bytes: smcFloatBytes(1_500))
        driver.setReadResults("F0Ac", [.success(smcFloatBytes(1_500)), .success(smcFloatBytes(2_000))])
        driver.setKey("TCMz", type: "flt ", bytes: smcFloatBytes(45))
        driver.setReadResults("TCMz", [.success(smcFloatBytes(45)), .success(smcFloatBytes(60))])
        driver.setKey("PSTR", type: "flt ", bytes: smcFloatBytes(12))
        driver.setReadResults("PSTR", [.success(smcFloatBytes(12)), .success(smcFloatBytes(18))])
        driver.setKey("B0AV", type: "ui16", bytes: [0xe0, 0x2e]) // 12 V, little endian
        driver.setReadResults("B0AV", [12_000, 12_100, 12_200, 12_300].map {
            .success([UInt8($0 & 0xff), UInt8($0 >> 8)])
        })
        let session = SMCReadSession(driver: driver, platform: .appleSilicon)

        var fans: [Int] = [], chips: [Double] = [], powers: [Double] = [], batteries: [Double] = []
        for _ in 0..<2 {
            fans.append(try XCTUnwrap(SMCFanSpeedService.currentFanReadings(connection: session, isPortable: false).first?.actualRPM))
            chips.append(try XCTUnwrap(SMCFanSpeedService.currentChipTemperatureCelsius(connection: session)))
            let power = SMCPowerTelemetryService.currentTelemetry(connection: session)
            powers.append(try XCTUnwrap(power.systemPowerWatts.value))
            batteries.append(try XCTUnwrap(power.battery.voltageVolts.value))
            batteries.append(try XCTUnwrap(SMCPowerTelemetryService.currentBatteryTelemetry(connection: session).voltageVolts.value))
        }
        XCTAssertEqual(fans, [1_500, 2_000])
        XCTAssertEqual(chips, [45, 60])
        XCTAssertEqual(powers, [12, 18])
        XCTAssertEqual(batteries.count, 4)
        for (actual, expected) in zip(batteries, [12, 12.1, 12.2, 12.3]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        XCTAssertEqual(driver.counts.opens, 1, "eight provider passes share one open instead of eight")
        XCTAssertTrue(driver.counts.keyInfo.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(driver.counts.bytes["F0Ac"], 2)
        XCTAssertEqual(driver.counts.bytes["TCMz"], 2)
        XCTAssertEqual(driver.counts.bytes["PSTR"], 2)
        XCTAssertEqual(driver.counts.bytes["B0AV"], 4, "power and battery each obtain actual bytes")
    }

    func testWholeThermalPassRetainsSamePassDeduplicationAndFreshNextPass() throws {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        driver.setKey("F0Ac", type: "flt ", bytes: smcFloatBytes(1_500))
        driver.setKey("TCMz", type: "flt ", bytes: smcFloatBytes(45))
        driver.setReadResults("TCMz", [.success(smcFloatBytes(45)), .success(smcFloatBytes(50))])
        let session = SMCReadSession(driver: driver, platform: .appleSilicon)

        let first = SMCFanSpeedService.currentHardwareReadings(connection: session, isPortable: false)
        let second = SMCFanSpeedService.currentHardwareReadings(connection: session, isPortable: false)
        XCTAssertEqual(first.chipTemperatureCelsius, 45)
        XCTAssertEqual(second.chipTemperatureCelsius, 50)
        XCTAssertEqual(first.fanCount, 1)
        XCTAssertEqual(try XCTUnwrap(second.fanReadings.first?.actualRPM), 1_500)
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertTrue(driver.counts.keyInfo.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(driver.counts.bytes["FNum"], 2, "count and fans share this pass's bytes")
        XCTAssertEqual(driver.counts.bytes["TCMz"], 2)
    }

    func testDefiniteMissingIsCachedWithoutByteReads() {
        let driver = CountingSMCReadDriver()
        let session = SMCReadSession(driver: driver, platform: .intel)
        for _ in 0..<3 { XCTAssertEqual(session.readRaw("NONE"), .missing) }
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertEqual(driver.counts.keyInfo["NONE"], 1, "three absent-key probes become one")
        XCTAssertNil(driver.counts.bytes["NONE"])
    }

    func testTemporaryKeyInfoFailureIsUnreadableAndDiscoveryRetries() {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [2])
        driver.setInfoResults("FNum", [.unreadable, .success(.init(dataSize: 1, dataType: "ui8 "))])
        let session = SMCReadSession(driver: driver, platform: .intel)

        XCTAssertEqual(session.readRaw("FNum"), .unreadable)
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [2]))
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [2]))
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 2, "failed metadata is never cached")
        XCTAssertEqual(driver.counts.bytes["FNum"], 2)
        XCTAssertEqual(driver.counts.opens, 1)
    }

    func testTemporaryValueFailureAndShortPayloadAreRetriedWithoutCachingValues() {
        let driver = CountingSMCReadDriver()
        driver.setKey("PSTR", type: "flt ", bytes: smcFloatBytes(0))
        driver.setReadResults("PSTR", [.unreadable, .success([0]), .success(smcFloatBytes(0)), .success(smcFloatBytes(8))])
        let session = SMCReadSession(driver: driver, platform: .appleSilicon)

        XCTAssertEqual(session.readRaw("PSTR"), .unreadable)
        XCTAssertEqual(session.readRaw("PSTR"), .unreadable, "a short response is not a sample")
        XCTAssertEqual(session.readRaw("PSTR"), .present(dataType: "flt ", bytes: smcFloatBytes(0)))
        XCTAssertEqual(session.readRaw("PSTR"), .present(dataType: "flt ", bytes: smcFloatBytes(8)))
        XCTAssertEqual(driver.counts.keyInfo["PSTR"], 1)
        XCTAssertEqual(driver.counts.bytes["PSTR"], 4)
        XCTAssertEqual(driver.counts.opens, 1)
    }

    func testMalformedMetadataIsNotCached() {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [2])
        driver.setInfoResults("FNum", [
            .success(.init(dataSize: 0, dataType: "ui8 ")),
            .success(.init(dataSize: 33, dataType: "ui8 ")),
            .success(.init(dataSize: 1, dataType: "bad")),
            .success(.init(dataSize: 1, dataType: "ui8 "))
        ])
        let session = SMCReadSession(driver: driver, platform: .intel)
        for _ in 0..<3 { XCTAssertEqual(session.readRaw("FNum"), .unreadable) }
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [2]))
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 4)
        XCTAssertEqual(driver.counts.bytes["FNum"], 1)
    }

    func testInjectedSleepWakeNotificationsCloseInvalidateAndReconnectLazily() {
        let center = NotificationCenter()
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        let session = SMCReadSession(driver: driver, platform: .intel, lifecycleCenter: center)
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [1]))
        XCTAssertEqual(session.readRaw("NONE"), .missing)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(session.readRaw("FNum"), .unreadable)
        XCTAssertEqual(driver.counts.opens, 1, "never open while sleeping")
        XCTAssertEqual(driver.waitForClose(timeout: .now() + 1), .success, "sleep cleanup is queued after active reads")
        XCTAssertEqual(driver.counts.closes, 1)
        XCTAssertEqual(driver.counts.bytes["FNum"], 1)
        driver.setKey("FNum", type: "ui16", bytes: [0, 2])
        driver.setKey("NONE", type: "ui8 ", bytes: [0])
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(driver.counts.opens, 1, "wake itself does no hardware work")
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui16", bytes: [0, 2]))
        XCTAssertEqual(session.readRaw("NONE"), .present(dataType: "ui8 ", bytes: [0]))
        XCTAssertEqual(driver.counts.opens, 2)
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 2, "positive cache is connection-local")
        XCTAssertEqual(driver.counts.keyInfo["NONE"], 2, "negative cache is connection-local")
    }

    func testWakeWithoutObservedSleepAlsoInvalidatesConnection() {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        let session = SMCReadSession(driver: driver, platform: .intel)
        _ = session.readRaw("FNum")
        session.setSleeping(false)
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertEqual(driver.waitForClose(timeout: .now() + 1), .success, "wake cleanup is asynchronous")
        XCTAssertEqual(driver.counts.closes, 1)
        _ = session.readRaw("FNum")
        XCTAssertEqual(driver.counts.opens, 2)
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 2)
    }

    func testKeyInfoTransportLossDropsPositiveAndNegativeCache() {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        driver.setInfoResults("LOST", [.disconnected])
        let session = SMCReadSession(driver: driver, platform: .intel)
        _ = session.readRaw("FNum")
        XCTAssertEqual(session.readRaw("NONE"), .missing)
        XCTAssertEqual(session.readRaw("LOST"), .unreadable)
        driver.setKey("FNum", type: "ui16", bytes: [0, 2])
        driver.setKey("NONE", type: "ui8 ", bytes: [0])
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui16", bytes: [0, 2]))
        XCTAssertEqual(session.readRaw("NONE"), .present(dataType: "ui8 ", bytes: [0]))
        XCTAssertEqual(driver.counts.opens, 2)
        XCTAssertEqual(driver.counts.closes, 1)
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 2)
        XCTAssertEqual(driver.counts.keyInfo["NONE"], 2)
    }

    func testByteTransportLossDoesNotReopenForEveryRemainingProbeInPass() {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        driver.setReadResults("FNum", [.disconnected, .success([2])])
        let session = SMCReadSession(driver: driver, platform: .intel)
        let results = session.withReadPass(fallback: [SMCKeyRead]()) { reader in
            [reader.readRaw("FNum"), reader.readRaw("NEXT"), reader.readRaw("FNum")]
        }
        XCTAssertEqual(results, [.unreadable, .unreadable, .unreadable])
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertNil(driver.counts.keyInfo["NEXT"])
        XCTAssertEqual(driver.counts.bytes["FNum"], 1)
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [2]))
        XCTAssertEqual(driver.counts.opens, 2)
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 2)
    }

    func testFailedOpenCostsOneAttemptPerProviderPassAndNextPassRetries() {
        let driver = CountingSMCReadDriver()
        driver.setOpenResults([false, true])
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        let session = SMCReadSession(driver: driver, platform: .intel)
        XCTAssertTrue(SMCFanSpeedService.currentHardwareReadings(connection: session, isPortable: false).fanReadings.isEmpty)
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertTrue(driver.counts.keyInfo.isEmpty)
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [1]))
        XCTAssertEqual(driver.counts.opens, 2)
    }

    func testFailedOpenIsInvalidAtPowerAndBatteryProvidersInsteadOfUnsupported() {
        let driver = CountingSMCReadDriver()
        driver.setOpenResults([false, false])
        let session = SMCReadSession(driver: driver, platform: .appleSilicon)
        XCTAssertEqual(SMCPowerTelemetryService.currentTelemetry(connection: session).systemPowerWatts, .invalid)
        XCTAssertEqual(SMCPowerTelemetryService.currentBatteryTelemetry(connection: session).voltageVolts, .invalid)
        XCTAssertEqual(driver.counts.opens, 2, "one attempt per provider pass")
        XCTAssertTrue(driver.counts.keyInfo.isEmpty)
        XCTAssertTrue(driver.counts.bytes.isEmpty)
    }

    func testConcurrentCallersSerializeAllDriverWorkAndShareMetadata() {
        let driver = CountingSMCReadDriver(yieldDuringCalls: true)
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        let session = SMCReadSession(driver: driver, platform: .intel)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in _ = session.readRaw("FNum") }
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 1)
        XCTAssertEqual(driver.counts.bytes["FNum"], 64)
        XCTAssertEqual(driver.counts.maximumConcurrentCalls, 1)
    }

    func testConcurrentSleepWakeObserversSerializeCloseWithReads() {
        let center = NotificationCenter()
        let driver = CountingSMCReadDriver(yieldDuringCalls: true)
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        let session = SMCReadSession(driver: driver, platform: .intel, lifecycleCenter: center)
        _ = session.readRaw("FNum")
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            switch index % 3 {
            case 0: center.post(name: NSWorkspace.willSleepNotification, object: nil)
            case 1: center.post(name: NSWorkspace.didWakeNotification, object: nil)
            default: _ = session.readRaw("FNum")
            }
        }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [1]))
        XCTAssertEqual(driver.counts.maximumConcurrentCalls, 1, "callbacks and reads use the same serial lock")
    }

    func testSleepReturnsWithinFiftyMillisecondsDuringBlockedReadAndDefersInvalidation() {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        let session = SMCReadSession(driver: driver, platform: .intel)
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [1]))
        XCTAssertEqual(session.readRaw("NONE"), .missing)

        let gate = driver.blockNextByteRead()
        XCTAssertEqual(session.cachedKeyInfoCount, 2, "both positive and negative descriptions are prewarmed")
        let results = SMCReadResultBox()
        let workers = DispatchGroup()
        workers.enter()
        DispatchQueue.global().async {
            results.set(session.withReadPass(fallback: [SMCKeyRead.unreadable, .unreadable]) { reader in
                [reader.readRaw("FNum"), reader.readRaw("NEXT")]
            })
            workers.leave()
        }
        defer {
            gate.release()
            XCTAssertEqual(workers.wait(timeout: .now() + 2), .success, "all controlled workers must finish")
        }
        let entered = gate.waitUntilEntered(timeout: .now() + 1)
        XCTAssertEqual(entered, .success)
        guard entered == .success else { return }

        let callbackStarted = DispatchSemaphore(value: 0)
        let callbackReturned = DispatchSemaphore(value: 0)
        let timing = SMCCallbackTiming()
        workers.enter()
        DispatchQueue.global().async {
            callbackStarted.signal()
            let start = DispatchTime.now().uptimeNanoseconds
            session.setSleeping(true)
            timing.set(DispatchTime.now().uptimeNanoseconds - start)
            callbackReturned.signal()
            workers.leave()
        }
        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 1), .success)
        let returned = callbackReturned.wait(timeout: .now() + .milliseconds(50))
        XCTAssertEqual(returned, .success, "sleep callback must not wait for the blocked driver")
        guard returned == .success else {
            // The blocking-callback counterexample must finish as an assertion
            // failure, rather than leave its deliberately blocked driver alive.
            gate.release()
            XCTAssertEqual(callbackReturned.wait(timeout: .now() + 1), .success)
            XCTAssertLessThan(timing.nanoseconds ?? UInt64.max, 50_000_000)
            return
        }
        XCTAssertLessThan(timing.nanoseconds ?? UInt64.max, 50_000_000)
        XCTAssertEqual(driver.counts.closes, 0, "never close a connection while its physical read is active")
        for _ in 0..<3 { XCTAssertEqual(session.readRaw("FNum"), .unreadable) }
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 1)
        XCTAssertEqual(driver.counts.bytes["FNum"], 2, "sleeping requests add no physical reads")

        gate.release()
        XCTAssertEqual(workers.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(driver.waitForClose(timeout: .now() + 1), .success)
        XCTAssertEqual(results.values, [.unreadable, .unreadable], "the interrupted pass cannot publish old-generation bytes")
        XCTAssertEqual(driver.counts.closes, 1)
        XCTAssertEqual(session.cachedKeyInfoCount, 0, "sleep cleanup clears both caches before wake")
        XCTAssertNil(driver.counts.keyInfo["NEXT"], "remaining probes cannot begin while sleeping")
        driver.setKey("FNum", type: "ui16", bytes: [0, 2])
        driver.setKey("NONE", type: "ui8 ", bytes: [0])
        session.setSleeping(false)
        XCTAssertEqual(driver.counts.opens, 1, "wake does not reconnect eagerly")
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui16", bytes: [0, 2]))
        XCTAssertEqual(session.readRaw("NONE"), .present(dataType: "ui8 ", bytes: [0]))
        XCTAssertEqual(driver.counts.opens, 2)
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 2, "sleep cleared the positive metadata cache")
        XCTAssertEqual(driver.counts.keyInfo["NONE"], 2, "sleep cleared the negative metadata cache")
        XCTAssertEqual(driver.counts.maximumConcurrentCalls, 1)
    }

    func testSleepWakeDuringBlockedPassRejectsOldGenerationAndDefersFurtherReads() {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        driver.setKey("NEXT", type: "ui8 ", bytes: [9])
        let session = SMCReadSession(driver: driver, platform: .intel)
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [1]))
        let gate = driver.blockNextByteRead()
        let results = SMCReadResultBox()
        let worker = DispatchGroup()
        worker.enter()
        DispatchQueue.global().async {
            results.set(session.withReadPass(fallback: [SMCKeyRead.unreadable, .unreadable]) { reader in
                [reader.readRaw("FNum"), reader.readRaw("NEXT")]
            })
            worker.leave()
        }
        defer {
            gate.release()
            XCTAssertEqual(worker.wait(timeout: .now() + 2), .success)
        }
        let entered = gate.waitUntilEntered(timeout: .now() + 1)
        XCTAssertEqual(entered, .success)
        guard entered == .success else { return }
        session.setSleeping(true)
        session.setSleeping(false)
        XCTAssertEqual(driver.counts.closes, 0)
        gate.release()
        XCTAssertEqual(worker.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(driver.waitForClose(timeout: .now() + 1), .success)
        XCTAssertEqual(results.values, [.unreadable, .unreadable], "wake must not requalify the old pass")
        XCTAssertNil(driver.counts.keyInfo["NEXT"])
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [1]))
        XCTAssertEqual(session.readRaw("NEXT"), .present(dataType: "ui8 ", bytes: [9]))
        XCTAssertEqual(driver.counts.opens, 2)
        XCTAssertEqual(driver.counts.closes, 1)
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 2)
        XCTAssertEqual(driver.counts.keyInfo["NEXT"], 1)
        XCTAssertEqual(driver.counts.maximumConcurrentCalls, 1)
    }

    func testPowerTelemetryDiscardsEntirePassWhenSecondReadSpansSleepWakeAndRereadsAfterWake() {
        let driver = CountingSMCReadDriver()
        driver.setKey("PSTR", type: "flt ", bytes: smcFloatBytes(12))
        driver.setKey("PDTR", type: "flt ", bytes: smcFloatBytes(8))
        let session = SMCReadSession(driver: driver, platform: .appleSilicon)
        // Use the production aggregate: PSTR succeeds before PDTR blocks.
        // Only PDTR is gated, so the first field is already in the old result.
        let gate = driver.blockNextByteRead(for: "PDTR")
        let results = SMCPowerTelemetryResultBox()
        let worker = DispatchGroup()
        worker.enter()
        DispatchQueue.global().async {
            results.set(SMCPowerTelemetryService.currentTelemetry(connection: session))
            worker.leave()
        }
        defer {
            gate.release()
            XCTAssertEqual(worker.wait(timeout: .now() + 2), .success, "the controlled worker must finish")
        }
        let entered = gate.waitUntilEntered(timeout: .now() + 1)
        XCTAssertEqual(entered, .success)
        guard entered == .success else { return }
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertEqual(driver.counts.keyInfo, ["PSTR": 1, "PDTR": 1])
        XCTAssertEqual(driver.counts.bytes, ["PSTR": 1, "PDTR": 1], "the first physical value completed before the second blocked")

        session.setSleeping(true)
        session.setSleeping(false)
        XCTAssertEqual(driver.counts.closes, 0, "both lifecycle cleanups must wait for the active physical read")
        gate.release()
        XCTAssertEqual(worker.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(driver.waitForClose(timeout: .now() + 1), .success)
        XCTAssertEqual(session.cachedKeyInfoCount, 0, "sleep and wake clear metadata before the next pass")
        let fallback = SMCPowerTelemetryService.telemetry(read: { _ in .unreadable }, platform: .appleSilicon)
        XCTAssertEqual(results.value, fallback, "the whole production aggregate must fall back, including the earlier PSTR value")
        XCTAssertEqual(results.value?.systemPowerWatts, .invalid, "removing the final generation guard must fail this assertion")
        XCTAssertEqual(results.value?.inputPowerWatts, .invalid)
        XCTAssertEqual(driver.counts.opens, 1, "wake does not reconnect eagerly")
        XCTAssertEqual(driver.counts.closes, 1)
        XCTAssertEqual(driver.counts.keyInfo, ["PSTR": 1, "PDTR": 1], "old-generation remaining probes perform no discovery")
        XCTAssertEqual(driver.counts.bytes, ["PSTR": 1, "PDTR": 1], "falling back performs no hardware work")

        driver.setKey("PSTR", type: "flt ", bytes: smcFloatBytes(18))
        driver.setKey("PDTR", type: "flt ", bytes: smcFloatBytes(20))
        let fresh = SMCPowerTelemetryService.currentTelemetry(connection: session)
        XCTAssertEqual(fresh.systemPowerWatts, .value(18))
        XCTAssertEqual(fresh.inputPowerWatts, .value(20))
        XCTAssertEqual(fresh.inputVoltageVolts, .unsupported, "the new pass also discovers its remaining probes")
        XCTAssertEqual(driver.counts.opens, 2)
        XCTAssertEqual(driver.counts.closes, 1)
        XCTAssertEqual(driver.counts.keyInfo["PSTR"], 2, "wake forces fresh metadata discovery")
        XCTAssertEqual(driver.counts.keyInfo["PDTR"], 2)
        XCTAssertEqual(driver.counts.keyInfo["VD0R"], 1, "the discarded pass never discovered this later key")
        XCTAssertEqual(driver.counts.bytes, ["PSTR": 2, "PDTR": 2], "the fresh pass physically rereads both values")
        XCTAssertEqual(driver.counts.maximumConcurrentCalls, 1)
    }

    func testPrewarmedMetadataSerializesControlledPhysicalReadsWithoutDictionaryMutation() {
        let driver = CountingSMCReadDriver()
        driver.setKey("FNum", type: "ui8 ", bytes: [1])
        let session = SMCReadSession(driver: driver, platform: .intel)
        // The serialization counterexample only removes queue serialization.
        // Open and metadata are established before either concurrent pass; its
        // two passes read immutable cache entries and cannot race a dictionary
        // insertion or connection change. The driver has its own short lock.
        XCTAssertEqual(session.readRaw("FNum"), .present(dataType: "ui8 ", bytes: [1]))
        XCTAssertEqual(driver.waitForByteRead(timeout: .now()), .success)
        let gate = driver.blockNextByteRead()
        let results = SMCReadResultBox()
        let workers = DispatchGroup()
        workers.enter()
        DispatchQueue.global().async {
            results.append(session.readRaw("FNum"))
            workers.leave()
        }
        defer {
            gate.release()
            XCTAssertEqual(workers.wait(timeout: .now() + 2), .success)
        }
        let entered = gate.waitUntilEntered(timeout: .now() + 1)
        XCTAssertEqual(entered, .success)
        guard entered == .success else { return }
        XCTAssertEqual(driver.waitForByteRead(timeout: .now()), .success)
        let secondAttemptStarted = DispatchSemaphore(value: 0)
        workers.enter()
        DispatchQueue.global().async {
            secondAttemptStarted.signal()
            results.append(session.readRaw("FNum"))
            workers.leave()
        }
        XCTAssertEqual(secondAttemptStarted.wait(timeout: .now() + 1), .success)
        // Keep the first physical call blocked until a competing call either
        // enters the driver (the mutation) or remains behind the serial queue.
        XCTAssertEqual(driver.waitForByteRead(timeout: .now() + .milliseconds(50)), .timedOut, "the competing physical read must remain queued")
        gate.release()
        XCTAssertEqual(workers.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(results.values, Array(repeating: .present(dataType: "ui8 ", bytes: [1]), count: 2))
        XCTAssertEqual(driver.counts.opens, 1)
        XCTAssertEqual(driver.counts.keyInfo["FNum"], 1)
        XCTAssertEqual(driver.counts.bytes["FNum"], 3, "prewarm plus two actual physical reads")
        XCTAssertEqual(driver.counts.closes, 0)
        XCTAssertEqual(driver.counts.maximumConcurrentCalls, 1, "removing queue serialization must fail this assertion")
    }

    func testCacheHasBoundedKeyCountAndEvictedMetadataIsReadAgain() {
        let driver = CountingSMCReadDriver()
        let session = SMCReadSession(driver: driver, platform: .intel)
        XCTAssertEqual(session.readRaw("0000"), .missing)
        for index in 1...512 { _ = session.readRaw(String(format: "%04X", index)) }
        XCTAssertEqual(session.readRaw("0000"), .missing)
        XCTAssertEqual(driver.counts.keyInfo["0000"], 2, "bounded cache must release old entries")
        XCTAssertEqual(driver.counts.opens, 1)
    }

    func testOnlyExplicitDeviceNotFoundCanBecomeMissing() {
        let missing: SMCDriverRead<SMCKeyInfo> = SMCReadFailure.classify(transportSucceeded: true, deviceResult: 0x84)
        XCTAssertEqual(missing, .missing)
        for result in [UInt8(0x80), 0x81, 0x85, 0xff] {
            let temporary: SMCDriverRead<SMCKeyInfo> = SMCReadFailure.classify(transportSucceeded: true, deviceResult: result)
            XCTAssertEqual(temporary, .unreadable)
        }
        let transport: SMCDriverRead<SMCKeyInfo> = SMCReadFailure.classify(transportSucceeded: false, deviceResult: 0x84)
        XCTAssertEqual(transport, .disconnected, "an output after transport failure cannot prove absence")
    }
}

// Unconditionally compiled: SwiftPM Release also builds these tests.
private func smcFloatBytes(_ value: Float) -> [UInt8] {
    let bits = value.bitPattern
    return [0, 8, 16, 24].map { UInt8((bits >> $0) & 0xff) }
}

private final class SMCByteReadGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func waitUntilEntered(timeout: DispatchTime) -> DispatchTimeoutResult { entered.wait(timeout: timeout) }
    func release() { released.signal() }
    func waitForRelease() {
        entered.signal()
        released.wait()
    }
}

private final class SMCReadResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SMCKeyRead] = []

    var values: [SMCKeyRead] { lock.withLock { results } }
    func set(_ values: [SMCKeyRead]) { lock.withLock { results = values } }
    func append(_ value: SMCKeyRead) { lock.withLock { results.append(value) } }
}

private final class SMCPowerTelemetryResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: SMCPowerTelemetry?

    var value: SMCPowerTelemetry? { lock.withLock { result } }
    func set(_ value: SMCPowerTelemetry) { lock.withLock { result = value } }
}

private final class SMCCallbackTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: UInt64?

    var nanoseconds: UInt64? { lock.withLock { elapsed } }
    func set(_ value: UInt64) { lock.withLock { elapsed = value } }
}

private final class CountingSMCReadDriver: SMCReadDriver, @unchecked Sendable {
    struct Counts {
        var opens = 0
        var closes = 0
        var keyInfo: [String: Int] = [:]
        var bytes: [String: Int] = [:]
        var maximumConcurrentCalls = 0
    }
    private let lock = NSLock()
    private let yieldDuringCalls: Bool
    private let closeCompleted = DispatchSemaphore(value: 0)
    private let byteReadEntered = DispatchSemaphore(value: 0)
    private var counters = Counts()
    private var activeCalls = 0
    private var openResults: [Bool] = []
    private var infos: [String: SMCKeyInfo] = [:]
    private var values: [String: [UInt8]] = [:]
    private var infoResults: [String: [SMCDriverRead<SMCKeyInfo>]] = [:]
    private var readResults: [String: [SMCDriverRead<[UInt8]>]] = [:]
    private var byteReadGate: SMCByteReadGate?
    private var byteReadGateKey: String?

    init(yieldDuringCalls: Bool = false) { self.yieldDuringCalls = yieldDuringCalls }

    var counts: Counts { locked { counters } }

    func setKey(_ key: String, type: String, bytes: [UInt8]) {
        locked {
            infos[key] = .init(dataSize: UInt32(bytes.count), dataType: type)
            values[key] = bytes
        }
    }
    func setOpenResults(_ results: [Bool]) { locked { openResults = results } }
    func setInfoResults(_ key: String, _ results: [SMCDriverRead<SMCKeyInfo>]) { locked { infoResults[key] = results } }
    func setReadResults(_ key: String, _ results: [SMCDriverRead<[UInt8]>]) { locked { readResults[key] = results } }
    func blockNextByteRead(for key: String? = nil) -> SMCByteReadGate {
        let gate = SMCByteReadGate()
        locked {
            byteReadGate = gate
            byteReadGateKey = key
        }
        return gate
    }
    func waitForClose(timeout: DispatchTime) -> DispatchTimeoutResult { closeCompleted.wait(timeout: timeout) }
    func waitForByteRead(timeout: DispatchTime) -> DispatchTimeoutResult { byteReadEntered.wait(timeout: timeout) }

    func open() -> Bool {
        beginCall()
        defer { endCall() }
        return locked {
            counters.opens += 1
            return openResults.isEmpty ? true : openResults.removeFirst()
        }
    }
    func close() {
        beginCall()
        defer {
            endCall()
            closeCompleted.signal()
        }
        locked { counters.closes += 1 }
    }
    func keyInfo(for key: UInt32) -> SMCDriverRead<SMCKeyInfo> {
        beginCall()
        defer { endCall() }
        let name = keyName(key)
        return locked {
            counters.keyInfo[name, default: 0] += 1
            if var pending = infoResults[name], !pending.isEmpty {
                let result = pending.removeFirst()
                infoResults[name] = pending
                return result
            }
            return infos[name].map { .success($0) } ?? .missing
        }
    }
    func readBytes(for key: UInt32, info _: SMCKeyInfo) -> SMCDriverRead<[UInt8]> {
        beginCall()
        defer { endCall() }
        let name = keyName(key)
        let (gate, result): (SMCByteReadGate?, SMCDriverRead<[UInt8]>) = locked {
            counters.bytes[name, default: 0] += 1
            let gate: SMCByteReadGate?
            if byteReadGateKey == nil || byteReadGateKey == name {
                gate = byteReadGate
                byteReadGate = nil
                byteReadGateKey = nil
            } else {
                gate = nil
            }
            if var pending = readResults[name], !pending.isEmpty {
                let result = pending.removeFirst()
                readResults[name] = pending
                return (gate, result)
            }
            return (gate, values[name].map { .success($0) } ?? .unreadable)
        }
        byteReadEntered.signal()
        gate?.waitForRelease()
        return result
    }
    private func keyName(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .utf8) ?? ""
    }
    private func beginCall() {
        locked {
            activeCalls += 1
            counters.maximumConcurrentCalls = max(counters.maximumConcurrentCalls, activeCalls)
        }
        if yieldDuringCalls { for _ in 0..<128 { sched_yield() } }
    }
    private func endCall() { locked { activeCalls -= 1 } }
    private func locked<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
