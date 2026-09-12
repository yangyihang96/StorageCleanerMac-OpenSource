import XCTest
@testable import StorageCleanerMac

final class NativeNetworkProcessServiceTests: XCTestCase {
    func testParserUsesDeltaBlockAndReturnsTopFiveActiveProcesses() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_721_600_000)
        let output = """
        ,bytes_in,bytes_out,
        cumulative.9001,999999,999999,
        ,bytes_in,bytes_out,
        idle.100,0,0,
        browser.101,400,100,
        sync helper.102,250,800,
        media.103,900,600,
        mail.104,50,10,
        chat.105,80,70,
        backup.106,110,100,
        seventh.107,1,1,
        malformed,row,
        """

        let snapshot = try XCTUnwrap(
            NativeNetworkProcessService.parse(output, generatedAt: generatedAt)
        )

        XCTAssertEqual(snapshot.generatedAt, generatedAt)
        XCTAssertEqual(snapshot.processes.count, 5)
        XCTAssertEqual(
            snapshot.processes.map(\.processIdentifier),
            [103, 102, 101, 106, 105]
        )
        XCTAssertFalse(snapshot.processes.contains { $0.name == "cumulative" })
        XCTAssertFalse(snapshot.processes.contains { $0.name == "idle" })
        XCTAssertEqual(snapshot.processes.first?.downloadBytesPerSecond, 900)
        XCTAssertEqual(snapshot.processes.first?.uploadBytesPerSecond, 600)
    }

    func testParserRejectsSingleCumulativeBlock() {
        let output = """
        ,bytes_in,bytes_out,
        browser.101,400,100,
        """

        XCTAssertNil(
            NativeNetworkProcessService.parse(output, generatedAt: Date())
        )
    }

    func testCommandRequestsOneSecondDeltaWithoutDNSResolution() {
        XCTAssertEqual(NativeNetworkProcessService.executablePath, "/usr/bin/nettop")
        XCTAssertTrue(NativeNetworkProcessService.arguments.contains("-d"))
        XCTAssertTrue(NativeNetworkProcessService.arguments.contains("-n"))
        XCTAssertTrue(NativeNetworkProcessService.arguments.contains("bytes_in,bytes_out"))
    }

    func testIconPathResolvesNestedHelpersToTheirContainingApplication() {
        let executablePath = "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper"

        XCTAssertEqual(
            NativeNetworkProcessService.resolvedApplicationIconPath(
                bundlePath: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app",
                executablePath: executablePath
            ),
            "/Applications/Browser.app"
        )
    }
}
