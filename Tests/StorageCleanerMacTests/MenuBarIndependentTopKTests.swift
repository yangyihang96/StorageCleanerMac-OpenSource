import XCTest
@testable import StorageCleanerMac

final class MenuBarIndependentTopKTests: XCTestCase {
    func testCPUAndDiskLeadersOutsideEnergyTopFiveRemainInTheirOwnLists() {
        let energy = (1...5).map { app(name: "Energy \($0)", pid: Int32($0), cpu: 6, watts: Double(10 - $0), read: 0) }
        let cpu = app(name: "CPU Leader", pid: 60, cpu: 99, watts: 0.1, read: 0)
        let disk = app(name: "Disk Leader", pid: 70, cpu: 0.1, watts: 0.01, read: 8_000, write: 9_000)
        let prepared = MenuBarPreparedProcesses(snapshot: snapshot(energy + [cpu, disk]))
        XCTAssertEqual(prepared.energy.map(\.name), energy.map(\.name))
        XCTAssertEqual(prepared.cpu.first?.id, cpu.id)
        // D129 (2026-10-19): the disk list keeps idle apps after the leader,
        // in name order, as iStat's top five has no threshold (was
        // `[disk.id]` alone).
        XCTAssertEqual(prepared.disk.map(\.id), [disk.id, cpu.id] + energy.prefix(3).map(\.id))
        XCTAssertFalse(prepared.energy.contains { $0.id == cpu.id || $0.id == disk.id })
        XCTAssertEqual(prepared.cpu.count, 5)
        XCTAssertEqual(prepared.snapshot.apps.count, 7)
    }

    func testAllListsUseNameThenPIDForMetricTiesIndependentOfInventoryOrder() {
        let apps = [app(name: "Zulu", pid: 3), app(name: "Alpha", pid: 9), app(name: "Alpha", pid: 2)]
        for inventory in [apps, Array(apps.reversed()), [apps[1], apps[0], apps[2]]] {
            let prepared = MenuBarPreparedProcesses(snapshot: snapshot(inventory))
            for list in [prepared.energy, prepared.cpu, prepared.disk] {
                XCTAssertEqual(list.flatMap(\.processIDs), [2, 9, 3])
            }
        }
    }

    /// D79 locks the energy tie order: equal current power falls to name,
    /// then the smallest PID, then the app ID (not CPU% or inventory order).
    func testEnergyTiesFollowNameThenPIDThenIDNotCPU() {
        let apps = [app(name: "Beta", pid: 5, cpu: 90, watts: 2), app(name: "Alpha", pid: 8, cpu: 6, watts: 2),
                    app(name: "Alpha", pid: 4, cpu: 7, watts: 2), app(name: "Gamma", pid: 1, cpu: 50, watts: 3)]
        for inventory in [apps, Array(apps.reversed())] {
            let energy = MenuBarPreparedProcesses(snapshot: snapshot(inventory)).energy
            XCTAssertEqual(energy.map(\.name), ["Gamma", "Alpha", "Alpha", "Beta"])
            XCTAssertEqual(energy.flatMap(\.processIDs), [1, 4, 8, 5])
        }
    }

    func testPIDReuseUsesTheCurrentSnapshotIdentityAndName() {
        let old = MenuBarPreparedProcesses(snapshot: snapshot([app(name: "Old App", pid: 42)]))
        let new = MenuBarPreparedProcesses(snapshot: snapshot([app(name: "New App", pid: 42)]))
        for list in [new.energy, new.cpu, new.disk] {
            XCTAssertEqual(list.first?.name, "New App")
            XCTAssertNotEqual(list.first?.id, old.cpu.first?.id)
            XCTAssertEqual(list.first?.processIDs, [42])
        }
    }

    func testZeroActivityAndNonApplicationsAreExcludedAndLimitIsIndependent() {
        let apps = [app(name: "Idle", pid: 1, cpu: 0, watts: 0, read: 0),
                    app(name: "Standalone", pid: 2, isApplication: false), app(name: "Active", pid: 3)]
        // D129 (2026-10-19): a limit of one leaves "Active" because it ranks
        // first; idle apps stay in the CPU and disk lists below it
        // (`testCPUAndDiskListsKeepIdleAppsBelowActiveOnes`).
        let prepared = MenuBarPreparedProcesses(snapshot: snapshot(apps), limit: 1)
        for list in [prepared.energy, prepared.cpu, prepared.disk] { XCTAssertEqual(list.map(\.name), ["Active"]) }
        let empty = MenuBarPreparedProcesses(snapshot: snapshot(apps), limit: 0)
        XCTAssertTrue(empty.energy.isEmpty && empty.cpu.isEmpty && empty.disk.isEmpty)
    }

    /// D129: iStat's `processesWithConfig:` filters only the energy list
    /// (power threshold, apps); the CPU and disk lists are the top five of
    /// the measured snapshot, zeros included. Non-finite CPU is no reading.
    func testCPUAndDiskListsKeepIdleAppsBelowActiveOnes() {
        let apps = [app(name: "Idle", pid: 1, cpu: 0, watts: 0, read: 0),
                    app(name: "Standalone", pid: 2, isApplication: false),
                    app(name: "Active", pid: 3),
                    app(name: "Broken", pid: 4, cpu: .nan, watts: 0, read: 0),
                    app(name: "Writer", pid: 5, cpu: 0, watts: 0, read: 0, write: 4_096)]
        let prepared = MenuBarPreparedProcesses(snapshot: snapshot(apps))
        XCTAssertEqual(prepared.energy.map(\.name), ["Active"])
        XCTAssertEqual(prepared.cpu.map(\.name), ["Active", "Idle", "Writer"])
        XCTAssertEqual(prepared.disk.map(\.name), ["Writer", "Active", "Broken", "Idle"])
        for list in [prepared.energy, prepared.cpu, prepared.disk] {
            XCTAssertFalse(list.contains { $0.name == "Standalone" })
        }
        let idleOnly = MenuBarPreparedProcesses(snapshot: snapshot((1...7).map {
            app(name: "Idle \($0)", pid: Int32($0), cpu: 0, watts: 0, read: 0)
        }))
        XCTAssertTrue(idleOnly.energy.isEmpty)
        XCTAssertEqual(idleOnly.cpu.map(\.name), (1...5).map { "Idle \($0)" })
        XCTAssertEqual(idleOnly.disk.map(\.name), (1...5).map { "Idle \($0)" })
    }

    private func app(name: String, pid: Int32, cpu: Double = 10, watts: Double = 1,
                     read: Int64 = 1, write: Int64 = 0, isApplication: Bool = true) -> EnergyImpactApp {
        .init(id: "\(name):\(pid)", name: name, path: "/fixture/\(name).app", iconPath: "",
              bundlePath: nil, bundleIdentifier: nil, measuredEnergyWh: 1, estimatedSupplementEnergyWh: 0,
              estimatedEnergyWh: 1, currentPowerWatts: watts, averagePowerWatts: watts, cpuPercent: cpu,
              diskReadBytesPerSecond: read, diskWriteBytesPerSecond: write, residentBytes: 1,
              cumulativeCPUSeconds: 1, longestRunningSeconds: 10, processCount: 1, measuredProcessCount: 1,
              processIDs: [pid], isApplication: isApplication)
    }

    private func snapshot(_ apps: [EnergyImpactApp]) -> EnergyImpactSnapshot {
        .init(generatedAt: Date(timeIntervalSince1970: 1_000), scanSeconds: 0, sampleSeconds: 1,
              uptimeSeconds: 100, apps: apps, processCount: apps.count, measuredProcessCount: apps.count,
              unmeasuredProcessCount: 0, measuredTotalEnergyWh: 1, estimatedSupplementEnergyWh: 0,
              calibrationWattsPerCore: 1, usesLocalCalibration: false)
    }
}
