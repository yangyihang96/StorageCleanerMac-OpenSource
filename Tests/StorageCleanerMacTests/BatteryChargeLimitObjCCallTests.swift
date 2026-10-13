import Foundation
import XCTest
@testable import StorageCleanerMac

final class BatteryChargeLimitObjCCallTests: XCTestCase {
    /// 红阶段是测试进程崩溃；主会话须在沙箱外单独跑。只调 Swift 替身。
    @MainActor
    func testNSErrorWritebackSurvivesAutoreleasePoolsForEveryErrorABI() {
        let object = ChargeLimitErrorSource()
        for _ in 0..<50 {
            autoreleasepool {
                for selector in ["currentChargeLimit:", "isSmartChargingCurrentlyEnabled:", "isMCLCurrentlyEnabled:"] {
                    XCTAssertNil(BatteryChargeLimitObjCCalls.unsignedValue(on: object, selectorName: selector))
                }
                XCTAssertNil(BatteryChargeLimitObjCCalls.byteValue(on: object, selectorName: "getMCLLimitWithError:"))
                XCTAssertNil(BatteryChargeLimitObjCCalls.limits(on: object, selectorName: "availableChargeLimitsWithError:"))
                XCTAssertNil(BatteryChargeLimitObjCCalls.engagement(on: object))
                XCTAssertFalse(BatteryChargeLimitObjCCalls.setByte(on: object, selectorName: "setMCLLimit:error:", value: 80))
                for selector in ["temporarilyDisableSmartCharging:", "temporarilyDisableMCL:", "temporarilyEnableCharging:", "enableMCL:", "disableMCL:"] {
                    XCTAssertFalse(BatteryChargeLimitObjCCalls.invoke(on: object, selectorName: selector))
                }
            }
        }
    }

    @MainActor
    func testMissingSelectorsFailClosedForEveryErrorABI() {
        let object = NSObject()
        XCTAssertNil(BatteryChargeLimitObjCCalls.unsignedValue(on: object, selectorName: "currentChargeLimit:"))
        XCTAssertNil(BatteryChargeLimitObjCCalls.byteValue(on: object, selectorName: "getMCLLimitWithError:"))
        XCTAssertNil(BatteryChargeLimitObjCCalls.limits(on: object, selectorName: "availableChargeLimitsWithError:"))
        XCTAssertNil(BatteryChargeLimitObjCCalls.engagement(on: object))
        XCTAssertFalse(BatteryChargeLimitObjCCalls.setByte(on: object, selectorName: "setMCLLimit:error:", value: 80))
        XCTAssertFalse(BatteryChargeLimitObjCCalls.invoke(on: object, selectorName: "temporarilyDisableSmartCharging:"))
    }

    func testManualEnabledDecoderRecognizesOnlyZeroAndOne() {
        XCTAssertEqual(BatteryChargeLimitObjCCalls.decodeManualEnabled(0), false)
        XCTAssertEqual(BatteryChargeLimitObjCCalls.decodeManualEnabled(1), true)
        for rawValue: UInt64? in [nil, 2, 3, 4, 255, UInt64.max] {
            XCTAssertNil(BatteryChargeLimitObjCCalls.decodeManualEnabled(rawValue))
        }
    }
}

@MainActor
private final class ChargeLimitErrorSource: NSObject {
    private func report(_ error: NSErrorPointer) {
        error?.pointee = NSError(domain: "ChargeLimitErrorSource", code: 7,
                                userInfo: ["iteration": UUID().uuidString])
    }

    @objc(currentChargeLimit:)
    func currentChargeLimit(_ error: NSErrorPointer) -> UInt64 { report(error); return 0 }
    @objc(isSmartChargingCurrentlyEnabled:)
    func smartEnabled(_ error: NSErrorPointer) -> UInt64 { report(error); return 0 }
    @objc(isMCLCurrentlyEnabled:)
    func manualEnabled(_ error: NSErrorPointer) -> UInt64 { report(error); return 0 }
    @objc(getMCLLimitWithError:)
    func manualLimit(_ error: NSErrorPointer) -> UInt8 { report(error); return 0 }
    @objc(availableChargeLimitsWithError:)
    func limits(_ error: NSErrorPointer) -> NSArray? { report(error); return nil }
    @objc(setMCLLimit:error:)
    func setLimit(_ limit: UInt8, error: NSErrorPointer) -> Bool { report(error); return false }
    @objc(isOBCEngaged:isMaxChargeLimited:chargingOverrideAllowed:withError:)
    func engagement(
        _ engaged: UnsafeMutablePointer<ObjCBool>,
        limited: UnsafeMutablePointer<ObjCBool>, allowed: UnsafeMutablePointer<ObjCBool>,
        error: NSErrorPointer
    ) -> Bool { report(error); return false }
    @objc(temporarilyDisableSmartCharging:)
    func disableSmart(_ error: NSErrorPointer) -> Bool { report(error); return false }
    @objc(temporarilyDisableMCL:)
    func disableManual(_ error: NSErrorPointer) -> Bool { report(error); return false }
    @objc(temporarilyEnableCharging:)
    func enableCharging(_ error: NSErrorPointer) -> Bool { report(error); return false }
    @objc(enableMCL:)
    func enableMCL(_ error: NSErrorPointer) -> Bool { report(error); return false }
    @objc(disableMCL:)
    func disableMCL(_ error: NSErrorPointer) -> Bool { report(error); return false }
}
