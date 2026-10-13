@preconcurrency import Darwin
import Foundation

enum SystemMonitorService {
    static func maximumReadingAge(samplingInterval: TimeInterval) -> TimeInterval {
        max(10, 2 * samplingInterval)
    }

    static func isReadingFresh(_ sampledAt: Date?, now: Date, samplingInterval: TimeInterval) -> Bool {
        guard let sampledAt else { return false }
        let age = now.timeIntervalSince(sampledAt)
        return age.isFinite && age >= 0 && age <= maximumReadingAge(samplingInterval: samplingInterval)
    }
    // The menu-bar total represents bytes on the physical uplink, not both
    // sides of a VPN tunnel. Keeping the `en*` allow-list also prevents a
    // provider-specific tunnel name from being counted as a second hop.
    private static let virtualNetworkInterfacePrefixes = [
        "lo", "awdl", "llw", "bridge", "gif", "stf", "utun", "ipsec", "ppp", "tun", "tap", "vnic", "vmnet"
    ]

    struct SnapshotResult: Sendable {
        let snapshot: SystemMonitorSnapshot
        let networkSample: NetworkMonitorSample?
        let memorySnapshot: MemorySnapshot?
    }

    struct ThermalReadings: Sendable {
        let gpuUsagePercent: Double?
        let gpuMemoryUsedBytes: Int64?
        let chipTemperatureCelsius: Double?
        let fanSpeedRPM: Int?
        let fanCount: Int?
        let fanSpeedsRPM: [Int]?
        let fanReadings: [SystemFanReading]?
        let temperatureReadings: [SystemTemperatureReading]?
        let temperatureDetails: [SystemTemperatureDetailReading]?
        /// Zones named from SMC key names alone (D57 "依据键名推断").
        var inferredTemperatureZones: Set<SystemTemperatureZone> = []
        /// Ambient light (`CurrentLux`), nil when not sampled.
        var ambientLight: HardwareReading<Double>? = nil

        init(
            gpuUsagePercent: Double?,
            gpuMemoryUsedBytes: Int64? = nil,
            chipTemperatureCelsius: Double?,
            fanSpeedRPM: Int?,
            fanCount: Int?,
            fanSpeedsRPM: [Int]? = nil,
            fanReadings: [SystemFanReading]? = nil,
            temperatureReadings: [SystemTemperatureReading]? = nil,
            temperatureDetails: [SystemTemperatureDetailReading]? = nil,
            inferredTemperatureZones: Set<SystemTemperatureZone> = [],
            ambientLight: HardwareReading<Double>? = nil
        ) {
            self.gpuUsagePercent = gpuUsagePercent
            self.gpuMemoryUsedBytes = gpuMemoryUsedBytes
            self.chipTemperatureCelsius = chipTemperatureCelsius
            self.fanSpeedRPM = fanSpeedRPM
            self.fanCount = fanCount
            self.fanSpeedsRPM = fanSpeedsRPM
            self.fanReadings = fanReadings
            self.temperatureReadings = temperatureReadings
            self.temperatureDetails = temperatureDetails
            self.inferredTemperatureZones = inferredTemperatureZones
            self.ambientLight = ambientLight
        }

        static let empty = ThermalReadings(
            gpuUsagePercent: nil,
            gpuMemoryUsedBytes: nil,
            chipTemperatureCelsius: nil,
            fanSpeedRPM: nil,
            fanCount: nil,
            fanSpeedsRPM: nil,
            fanReadings: nil,
            temperatureReadings: nil,
            temperatureDetails: nil
        )

        var hasAvailableSensorData: Bool {
            gpuUsagePercent?.isFinite == true
                || chipTemperatureCelsius?.isFinite == true
                || fanSpeedRPM != nil
                || fanSpeedsRPM?.isEmpty == false
                || fanReadings?.isEmpty == false
                || temperatureReadings?.isEmpty == false
                || temperatureDetails?.isEmpty == false
        }
    }

    struct CPUUsageTicks: Equatable, Sendable {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 {
            user + system + idle + nice
        }

        var active: UInt64 {
            user + system + nice
        }
    }

    struct LiveReadings: Sendable {
        let cpuUsagePercent: Double?
        let cpuUsageBreakdown: CPUUsageBreakdown?
        let cpuCoreUsagePercent: [Double]?
        let loadAverage: SystemLoadAverage?
        let systemUptimeSeconds: TimeInterval
        let systemBootAt: Date?
        let thermalState: SystemThermalState
        let thermal: ThermalReadings
        let sensorAvailability: SystemSensorAvailability
        let fanAvailability: SystemSensorAvailability?
        let networkSample: NetworkMonitorSample?

        init(
            cpuUsagePercent: Double?,
            cpuUsageBreakdown: CPUUsageBreakdown? = nil,
            cpuCoreUsagePercent: [Double]? = nil,
            loadAverage: SystemLoadAverage? = nil,
            systemUptimeSeconds: TimeInterval = 0,
            systemBootAt: Date? = nil,
            thermalState: SystemThermalState = .unknown,
            thermal: ThermalReadings,
            sensorAvailability: SystemSensorAvailability? = nil,
            fanAvailability: SystemSensorAvailability? = nil,
            networkSample: NetworkMonitorSample?
        ) {
            self.cpuUsagePercent = cpuUsagePercent
            self.cpuUsageBreakdown = cpuUsageBreakdown
            self.cpuCoreUsagePercent = cpuCoreUsagePercent
            self.loadAverage = loadAverage
            self.systemUptimeSeconds = max(0, systemUptimeSeconds)
            self.systemBootAt = systemBootAt
            self.thermalState = thermalState
            self.thermal = thermal
            self.sensorAvailability = sensorAvailability
                ?? (thermal.hasAvailableSensorData ? .available : .unavailable)
            self.fanAvailability = fanAvailability
            self.networkSample = networkSample
        }
    }

    static func snapshot(
        enabledKinds: Set<MenuBarMetricKind>,
        memorySnapshot: MemorySnapshot?,
        previousNetworkSample: NetworkMonitorSample?,
        thermalSamplingInterval: TimeInterval = SystemMonitorSamplingInterval.background,
        resolvesMissingMemorySnapshot: Bool = true,
        samplingPlan: MenuBarSamplingPlan? = nil,
        now: Date = Date()
    ) async -> SnapshotResult {
        let resolvedPlan: MenuBarSamplingPlan?
        if let samplingPlan { resolvedPlan = samplingPlan }
        else { resolvedPlan = await MenuBarSamplingContext.shared.plan }
        let result = await SystemMonitorSampler.shared.snapshot(
            enabledKinds: enabledKinds,
            memorySnapshot: memorySnapshot,
            previousNetworkSample: previousNetworkSample,
            thermalSamplingInterval: thermalSamplingInterval,
            resolvesMissingMemorySnapshot: resolvesMissingMemorySnapshot,
            samplingPlan: resolvedPlan,
            now: now
        )
        if resolvedPlan?.cadence.suspended == false {
            await MenuBarSamplingContext.shared.rememberPanelSnapshot(result.snapshot)
        }
        return result
    }

    static func buildSnapshot(
        enabledKinds: Set<MenuBarMetricKind>,
        memorySnapshot: MemorySnapshot?,
        previousNetworkSample: NetworkMonitorSample?,
        liveReadings: LiveReadings,
        sensorSampledAt: Date? = nil,
        gpuSampledAt: Date? = nil,
        now: Date
    ) -> SnapshotResult {
        let resolvedFanReadings = SMCFanSpeedService.resolvedFanReadings(
            liveReadings.thermal.fanReadings,
            fallbackSpeeds: liveReadings.thermal.fanSpeedsRPM
        )
        let resolvedMemorySnapshot = memorySnapshot
        let networkSample = enabledKinds.contains(.networkSpeed)
            ? liveReadings.networkSample
            : previousNetworkSample
        let throughputValues = networkThroughput(
            current: networkSample,
            previous: previousNetworkSample
        )
        let resolvedNetworkThroughput: NetworkMonitorThroughput?
        if let down = throughputValues.downBytesPerSecond,
           let up = throughputValues.upBytesPerSecond {
            resolvedNetworkThroughput = NetworkMonitorThroughput(
                downBytesPerSecond: down,
                upBytesPerSecond: up
            )
        } else {
            resolvedNetworkThroughput = nil
        }

        let metrics = MenuBarMetricKind.allCases
            .filter { enabledKinds.contains($0) }
            .map { kind in
                metric(
                    for: kind,
                    memorySnapshot: resolvedMemorySnapshot,
                    cpuUsagePercent: liveReadings.cpuUsagePercent,
                    thermal: liveReadings.thermal,
                    networkSample: networkSample,
                    networkThroughput: resolvedNetworkThroughput
                )
            }

        return SnapshotResult(
            snapshot: SystemMonitorSnapshot(
                generatedAt: now,
                metrics: metrics,
                networkThroughput: resolvedNetworkThroughput,
                cpuUsageBreakdown: liveReadings.cpuUsageBreakdown,
                cpuCoreUsagePercent: liveReadings.cpuCoreUsagePercent,
                loadAverage: liveReadings.loadAverage,
                systemUptimeSeconds: liveReadings.systemUptimeSeconds,
                systemBootAt: liveReadings.systemBootAt,
                thermalState: liveReadings.thermalState,
                fanSpeedsRPM: liveReadings.thermal.fanSpeedsRPM,
                fanCount: liveReadings.thermal.fanCount,
                fanReadings: resolvedFanReadings,
                temperatureReadings: liveReadings.thermal.temperatureReadings,
                temperatureDetails: liveReadings.thermal.temperatureDetails,
                gpuMemoryUsedBytes: liveReadings.thermal.gpuMemoryUsedBytes,
                sensorAvailability: liveReadings.sensorAvailability,
                fanAvailability: liveReadings.fanAvailability,
                inferredTemperatureZones: liveReadings.thermal.inferredTemperatureZones,
                ambientLight: liveReadings.thermal.ambientLight,
                sensorSampledAt: sensorSampledAt,
                gpuSampledAt: gpuSampledAt
            ),
            networkSample: networkSample,
            memorySnapshot: resolvedMemorySnapshot
        )
    }

    static func cpuUsagePercent(current: CPUUsageTicks, previous: CPUUsageTicks?) -> Double? {
        cpuUsageBreakdown(current: current, previous: previous)?.totalPercent
    }

    static func cpuUsageBreakdown(
        current: CPUUsageTicks,
        previous: CPUUsageTicks?
    ) -> CPUUsageBreakdown? {
        // CPU ticks are cumulative since boot. Without a prior reading there is
        // no interval to describe, so treating zero as a baseline fabricates a
        // current-looking, boot-lifetime average for the first chart sample.
        guard let previous else { return nil }
        guard current.user >= previous.user,
              current.system >= previous.system,
              current.idle >= previous.idle,
              current.nice >= previous.nice else { return nil }

        let totalDelta = current.total - previous.total
        guard totalDelta > 0 else { return nil }

        let userDelta = (current.user - previous.user) + (current.nice - previous.nice)
        let systemDelta = current.system - previous.system
        let divisor = Double(totalDelta)
        let userPercent = min(100, max(0, Double(userDelta) / divisor * 100))
        let systemPercent = min(100, max(0, Double(systemDelta) / divisor * 100))

        return CPUUsageBreakdown(
            totalPercent: min(100, userPercent + systemPercent),
            userPercent: userPercent,
            systemPercent: systemPercent
        )
    }

    static func loadAverage(from values: [Double], sampleCount: Int) -> SystemLoadAverage? {
        guard sampleCount >= 3, values.count >= 3 else { return nil }
        let samples = values.prefix(3).map { max(0, $0) }
        return SystemLoadAverage(
            oneMinute: samples[0],
            fiveMinutes: samples[1],
            fifteenMinutes: samples[2]
        )
    }

    static func networkThroughput(
        current: NetworkMonitorSample?,
        previous: NetworkMonitorSample?
    ) -> (downBytesPerSecond: Int64?, upBytesPerSecond: Int64?) {
        guard let current, let previous else {
            return (nil, nil)
        }

        let interval = current.date.timeIntervalSince(previous.date)
        guard interval > 0.2,
              !MenuBarSamplingGaps.crosses(MenuBarSamplingGaps.shared.intervals(),
                  from: previous.date, to: current.date) else { return (nil, nil) }

        // Interface changes and counter resets are missing observations, not
        // zero traffic. Leaving them absent preserves a truthful chart gap.
        guard current.receivedBytes >= previous.receivedBytes,
              current.sentBytes >= previous.sentBytes else {
            return (nil, nil)
        }

        let down = Double(current.receivedBytes - previous.receivedBytes) / interval
        let up = Double(current.sentBytes - previous.sentBytes) / interval
        guard down.isFinite, up.isFinite, down >= 0, up >= 0 else {
            return (nil, nil)
        }
        return (Int64(down), Int64(up))
    }

    private static func metric(
        for kind: MenuBarMetricKind,
        memorySnapshot: MemorySnapshot?,
        cpuUsagePercent: Double?,
        thermal: ThermalReadings,
        networkSample: NetworkMonitorSample?,
        networkThroughput: NetworkMonitorThroughput?
    ) -> SystemMonitorMetric {
        switch kind {
        case .cpuUsage:
            guard let value = cpuUsagePercent else {
                return unavailableMetric(kind, detail: L10n.text("读取受限", "Read restricted"))
            }
            return SystemMonitorMetric(
                kind: kind,
                value: percentString(value),
                detail: L10n.text("总处理器", "All processors"),
                isAvailable: true
            )
        case .gpuUsage:
            guard let value = thermal.gpuUsagePercent else {
                return unavailableMetric(kind, detail: L10n.text("未暴露统计", "Not exposed"))
            }
            return SystemMonitorMetric(
                kind: kind,
                value: percentString(value),
                detail: L10n.text("显卡驱动统计", "GPU driver stats"),
                isAvailable: true
            )
        case .memoryUsage:
            guard let memorySnapshot,
                  let physical = memorySnapshot.measurements.physicalBytes.value,
                  let used = memorySnapshot.measuredUsedBytes,
                  let ratio = memorySnapshot.measuredUsedRatio else {
                let detail = memorySnapshot?.measurements.availableBytes.unavailableDetail
                    ?? memorySnapshot?.measurements.physicalBytes.unavailableDetail
                    ?? L10n.text("待读取", "Not read yet")
                return unavailableMetric(kind, detail: detail)
            }
            return SystemMonitorMetric(
                kind: kind,
                value: percentString(ratio * 100),
                detail: L10n.text(
                    "\(ByteFormat.string(Int64(clamping: used))) / \(ByteFormat.string(Int64(clamping: physical)))",
                    "\(ByteFormat.string(Int64(clamping: used))) / \(ByteFormat.string(Int64(clamping: physical)))"
                ),
                isAvailable: true
            )
        case .chipTemperature:
            guard let value = thermal.chipTemperatureCelsius else {
                return unavailableMetric(kind, detail: L10n.text("未暴露传感器", "No exposed sensor"))
            }
            return SystemMonitorMetric(
                kind: kind,
                value: String(format: "%.0f°C", value),
                detail: L10n.text("实时芯片最高温", "Live chip peak"),
                isAvailable: true
            )
        case .fanSpeed:
            guard let value = thermal.fanSpeedRPM else {
                return unavailableMetric(kind, detail: L10n.text("无风扇或不可读", "No fan or unreadable"))
            }
            return SystemMonitorMetric(
                kind: kind,
                value: SystemFanSpeedFormat.string(value),
                detail: fanSpeedDetail(fanCount: thermal.fanCount),
                isAvailable: true
            )
        case .networkSpeed:
            guard networkSample != nil else {
                return unavailableMetric(kind, detail: L10n.text("读取受限", "Read restricted"))
            }
            guard let networkThroughput else {
                return SystemMonitorMetric(
                    kind: kind,
                    value: "↓ --",
                    detail: "↑ --",
                    isAvailable: true
                )
            }
            return SystemMonitorMetric(
                kind: kind,
                value: "↓ \(speedString(networkThroughput.downBytesPerSecond))",
                detail: "↑ \(speedString(networkThroughput.upBytesPerSecond))",
                isAvailable: true
            )
        }
    }

    static func currentCPUUsageTicks() -> CPUUsageTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return CPUUsageTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    static func currentCPUCoreUsageTicks() -> [CPUUsageTicks]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS,
              processorCount > 0,
              let info else { return nil }

        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                size
            )
        }

        let statesPerCore = Int(CPU_STATE_MAX)
        guard infoCount >= processorCount * natural_t(statesPerCore) else { return nil }

        return (0..<Int(processorCount)).map { processorIndex in
            let base = processorIndex * statesPerCore
            return CPUUsageTicks(
                user: UInt64(info[base + Int(CPU_STATE_USER)]),
                system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    static func cpuCoreUsagePercent(
        current: [CPUUsageTicks],
        previous: [CPUUsageTicks]?
    ) -> [Double]? {
        guard let previous, current.count == previous.count, !current.isEmpty else { return nil }
        let values = zip(current, previous).compactMap { current, previous in
            cpuUsageBreakdown(current: current, previous: previous)?.totalPercent
        }
        return values.count == current.count ? values : nil
    }

    static func currentLoadAverage() -> SystemLoadAverage? {
        var values = [Double](repeating: 0, count: 3)
        let sampleCount = values.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, Int32(buffer.count))
        }
        return loadAverage(from: values, sampleCount: Int(sampleCount))
    }

    // Read once outside SwiftUI rendering. ProcessInfo.systemUptime counts
    // awake time, so subtracting it from the wall clock is not a boot date.
    fileprivate static let measuredBootAt: Date? = {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size,
              bootTime.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec)
            + TimeInterval(bootTime.tv_usec) / 1_000_000)
    }()

    static func currentThermalState() -> SystemThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .unknown
        }
    }

    static func currentNetworkSample(now: Date) -> NetworkMonitorSample? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var seenInterfaces = Set<String>()
        var receivedBytes: Int64 = 0
        var sentBytes: Int64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let address = cursor {
            defer { cursor = address.pointee.ifa_next }
            guard let namePointer = address.pointee.ifa_name,
                  let socketAddress = address.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_LINK),
                  let rawData = address.pointee.ifa_data else { continue }

            let name = String(cString: namePointer)
            let flags = Int32(address.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  isPhysicalUplinkInterface(name),
                  seenInterfaces.insert(name).inserted else { continue }

            let data = rawData.assumingMemoryBound(to: if_data.self).pointee
            receivedBytes += Int64(clamping: data.ifi_ibytes)
            sentBytes += Int64(clamping: data.ifi_obytes)
        }

        guard !seenInterfaces.isEmpty else { return nil }
        return NetworkMonitorSample(date: now, receivedBytes: receivedBytes, sentBytes: sentBytes)
    }

    static func isPhysicalUplinkInterface(_ interfaceName: String) -> Bool {
        let name = interfaceName.lowercased()
        guard name.hasPrefix("en") else { return false }
        return !virtualNetworkInterfacePrefixes.contains(where: { name.hasPrefix($0) })
    }

    static func temperatureAndFanReadings() -> ThermalReadings {
        let batchID = PerformanceTelemetry.signposter.makeSignpostID()
        let batchState = PerformanceTelemetry.signposter.beginInterval(
            "SensorBatchRead",
            id: batchID
        )
        defer {
            PerformanceTelemetry.signposter.endInterval(
                "SensorBatchRead",
                batchState
            )
        }
        let smcID = PerformanceTelemetry.signposter.makeSignpostID()
        let smcState = PerformanceTelemetry.signposter.beginInterval(
            "SMCAccess",
            id: smcID
        )
        let smcReadings = SMCFanSpeedService.currentHardwareReadings()
        PerformanceTelemetry.signposter.endInterval("SMCAccess", smcState)
        let fanReadings = smcReadings.fanReadings
        let fanSpeeds = fanReadings.map(\.actualRPM)
        let smcFanSpeed = SMCFanSpeedService.averageRPM(from: fanSpeeds)
        let rawTemperatures = AppleSiliconTemperatureService.currentTemperatureReadings()
        let detailedTemperatures = Self.detailedTemperatures(
            smcDetails: smcReadings.temperatureDetails,
            smcPowerManagementCelsius: smcReadings.powerManagementTemperatureCelsius,
            hidReadings: rawTemperatures
        )
        let nativeBatteryTemperature = MenuBarBatteryElectricalCache.shared.snapshot()?.temperatureCelsius
        let chipTemperature = [
            AppleSiliconTemperatureService.chipTemperatureCelsius(from: rawTemperatures),
            smcReadings.chipTemperatureCelsius
        ].compactMap { $0 }.max()

        var hottestByZone: [SystemTemperatureZone: Double] = [:]
        let sourceTemperatures = AppleSiliconTemperatureService.regionalTemperatures(
            from: rawTemperatures
        ) + smcReadings.temperatureReadings
        for reading in sourceTemperatures {
            hottestByZone[reading.zone] = max(
                hottestByZone[reading.zone] ?? reading.celsius,
                reading.celsius
            )
        }
        // AppleSmartBattery is the authoritative electrical source for the
        // installed battery.  Prefer it over duplicated gas-gauge HID entries
        // and generic SMC fallbacks when it is available.
        if let nativeBatteryTemperature {
            hottestByZone[.battery] = nativeBatteryTemperature
        }
        let regionalTemperatures = Self.regionalTemperatures(
            hottestByZone: hottestByZone,
            chipTemperatureCelsius: chipTemperature
        )

        return ThermalReadings(
            gpuUsagePercent: nil,
            gpuMemoryUsedBytes: nil,
            chipTemperatureCelsius: chipTemperature,
            fanSpeedRPM: smcFanSpeed,
            fanCount: smcReadings.fanCount,
            fanSpeedsRPM: fanSpeeds.isEmpty ? nil : fanSpeeds,
            fanReadings: fanReadings.isEmpty ? nil : fanReadings,
            temperatureReadings: regionalTemperatures.isEmpty ? nil : regionalTemperatures,
            temperatureDetails: detailedTemperatures.isEmpty ? nil : detailedTemperatures,
            inferredTemperatureZones: smcReadings.inferredZones,
            ambientLight: AmbientLightService.currentLux()
        )
    }

    /// The temperature card's zones. D57: the "CPU" row (`.chip`) reads the
    /// same value as the level-one CPU ring (the chip temperature, which on
    /// M5 is the hottest `Tp*` core), never the power-management IC.
    static func regionalTemperatures(
        hottestByZone: [SystemTemperatureZone: Double],
        chipTemperatureCelsius: Double?
    ) -> [SystemTemperatureReading] {
        var byZone = hottestByZone
        if let chipTemperatureCelsius {
            byZone[.chip] = chipTemperatureCelsius
        }
        return SystemTemperatureZone.allCases.compactMap { zone in
            byZone[zone].map { SystemTemperatureReading(zone: zone, celsius: $0) }
        }
    }

    /// The hardware probes: the SMC core and GPU rows on M5, the named HID
    /// sensors elsewhere, and one "电源管理芯片" row (HID `PMU tdie*`, else
    /// the SMC per-PMU maxima).
    static func detailedTemperatures(
        smcDetails: [SystemTemperatureDetailReading],
        smcPowerManagementCelsius: Double?,
        hidReadings: [AppleSiliconTemperatureService.Reading]
    ) -> [SystemTemperatureDetailReading] {
        let pmuKeys = SMCFanSpeedService.rawTemperatureKeys(forDetailID: SystemTemperatureDetailReading.powerManagementID)
        func smcPMU(_ celsius: Double) -> SystemTemperatureDetailReading {
            var row = SystemTemperatureDetailReading.powerManagement(celsius: celsius)
            row.channel = MenuBarTemperatureChannel(source: .smc, rawKey: pmuKeys.joined(separator: ","),
                ordinal: 0, rawName: "PMU maxima", location: nil, confidence: .recognized)
            return row
        }
        guard !smcDetails.isEmpty else {
            // No verified SMC topology: HID channels are the inspector (D81).
            var candidates = AppleSiliconTemperatureService.detailedTemperatures(from: hidReadings)
            if !candidates.contains(where: { AppleSiliconTemperatureService.isPowerManagementTemperature($0.channel?.rawName ?? "") }),
               let value = smcPowerManagementCelsius {
                candidates.append(smcPMU(value))
            }
            return AppleSiliconTemperatureService.selectDetails(candidates)
        }
        // A verified SMC topology keeps its original rows plus the single D57
        // "电源管理芯片" summary. Independent HID services are not added to the
        // default list, so the row count and ordering stay those of the topology.
        let smc = smcDetails.map { reading in
            var reading = reading
            reading.channel = MenuBarTemperatureChannel(source: .smc,
                rawKey: SMCFanSpeedService.rawTemperatureKeys(forDetailID: reading.id).joined(separator: ","),
                ordinal: 0, rawName: reading.name,
                location: reading.zone.map(MenuBarTemperatureChannel.zoneTitle), confidence: .verified)
            return reading
        }
        if let hidPMU = AppleSiliconTemperatureService.powerManagementTemperatureCelsius(from: hidReadings) {
            var row = SystemTemperatureDetailReading.powerManagement(celsius: hidPMU)
            row.channel = MenuBarTemperatureChannel(source: .hid,
                rawKey: "PMU tdie*/tdev*", ordinal: 0, rawName: "PMU maxima",
                location: nil, confidence: .recognized)
            return smc + [row]
        }
        return smc + [smcPowerManagementCelsius.map(smcPMU)].compactMap { $0 }
    }

    private static func unavailableMetric(_ kind: MenuBarMetricKind, detail: String) -> SystemMonitorMetric {
        SystemMonitorMetric(
            kind: kind,
            value: L10n.text("不可用", "Unavailable"),
            detail: detail,
            isAvailable: false
        )
    }

    private static func percentString(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private static func speedString(_ bytesPerSecond: Int64) -> String {
        "\(ByteFormat.string(bytesPerSecond))/s"
    }

    private static func fanSpeedDetail(fanCount: Int?) -> String {
        guard let fanCount, fanCount > 1 else {
            return L10n.text("当前转速", "Current speed")
        }
        return L10n.text("\(fanCount) 个风扇平均", "\(fanCount) fan average")
    }
}

enum SystemMonitorSamplingInterval {
    static let background: TimeInterval = 15
    static let interactive: TimeInterval = 2
}

actor SystemMonitorSampler {
    static let shared = SystemMonitorSampler()
    private static let gpuSamplingInterval: TimeInterval = 1
    private static let gpuSampleTimeout: TimeInterval = 8
    private static let thermalSampleTimeout: TimeInterval = 12

    private let gpuReader: @Sendable () -> GPUPerformanceSnapshot?
    private let temperatureAndFanReader: @Sendable () -> SystemMonitorService.ThermalReadings
    typealias CPUCounterReader = @Sendable () -> (cores: [SystemMonitorService.CPUUsageTicks]?, total: SystemMonitorService.CPUUsageTicks?)
    private let cpuCounterReader: CPUCounterReader

    private var wasNetworkSampling = false
    private var previousCPUTicks: SystemMonitorService.CPUUsageTicks?
    private var previousCPUCoreTicks: [SystemMonitorService.CPUUsageTicks]?
    private var cachedGPUUsagePercent: Double?
    private var cachedGPUMemoryUsedBytes: Int64?
    private var gpuSampledAt: Date?
    private var isGPUSampleInFlight = false
    private var gpuSampleStartedAt: Date?
    private var gpuSampleGeneration: UInt64 = 0
    private var gpuSampleDidTimeOut = false
    private var cachedThermal = SystemMonitorService.ThermalReadings.empty
    private var thermalSampledAt: Date?
    private var isThermalSampleInFlight = false
    private var thermalSampleStartedAt: Date?
    private var thermalSampleGeneration: UInt64 = 0
    private var thermalSampleDidTimeOut = false
    /// A source left the sampling plan while its physical read was running:
    /// that read finishes (single-flight) but its value is not kept.
    private var discardsGPUInFlight = false
    private var discardsThermalInFlight = false
    private var previousCPUSampleAt: Date?
    private var lastCPUBreakdown: CPUUsageBreakdown?
    private var lastCPUCorePercents: [Double]?
    /// Same floor as `SystemMonitorService.networkThroughput`.
    static let minimumCPUDeltaInterval: TimeInterval = 0.2
    var isHardwareReadInFlight: Bool { isGPUSampleInFlight || isThermalSampleInFlight }

    /// D74: sleep stops collection without dropping the presentation owner's
    /// stored reading. Synchronous drivers retain their physical flight gate.
    func suspendResidentSampling() {
        clearGPUCache()
        clearThermalCache()
        previousCPUTicks = nil
        previousCPUCoreTicks = nil
        previousCPUSampleAt = nil
        lastCPUBreakdown = nil
        lastCPUCorePercents = nil
        wasNetworkSampling = false
    }

    init(
        gpuReader: @escaping @Sendable () -> GPUPerformanceSnapshot? = { GPUPerformanceService.currentSnapshot() },
        temperatureAndFanReader: @escaping @Sendable () -> SystemMonitorService.ThermalReadings = {
            SystemMonitorService.temperatureAndFanReadings()
        },
        cpuCounterReader: @escaping CPUCounterReader = {
            let cores = SystemMonitorService.currentCPUCoreUsageTicks()
            return (cores, cores.map(SystemMonitorSampler.totalTicks(fromCoreTicks:))
                ?? SystemMonitorService.currentCPUUsageTicks())
        }
    ) {
        self.gpuReader = gpuReader
        self.temperatureAndFanReader = temperatureAndFanReader
        self.cpuCounterReader = cpuCounterReader
    }

    func snapshot(
        enabledKinds: Set<MenuBarMetricKind>,
        memorySnapshot: MemorySnapshot?,
        previousNetworkSample: NetworkMonitorSample?,
        thermalSamplingInterval: TimeInterval = SystemMonitorSamplingInterval.background,
        resolvesMissingMemorySnapshot: Bool = true,
        samplingPlan: MenuBarSamplingPlan? = nil,
        now: Date
    ) async -> SystemMonitorService.SnapshotResult {
        let samplingKinds = samplingPlan.map { enabledKinds.intersection($0.primaryKinds) } ?? enabledKinds
        // Review P1-1: a source that leaves the plan drops its cache, so a
        // reopen hours later never publishes (or writes to history) an old
        // GPU or SMC reading under the current snapshot time.
        if !samplingKinds.contains(.gpuUsage) {
            clearGPUCache()
        } else if !SystemMonitorService.isReadingFresh(gpuSampledAt, now: now,
                    samplingInterval: samplingPlan?.gpuInterval ?? Self.gpuSamplingInterval) {
            clearGPUCache(discardInFlight: false)
        }
        if samplingKinds.isDisjoint(with: [.chipTemperature, .fanSpeed]) {
            clearThermalCache()
        } else if !SystemMonitorService.isReadingFresh(thermalSampledAt, now: now,
                    samplingInterval: samplingPlan?.thermalInterval ?? thermalSamplingInterval) {
            clearThermalCache(discardInFlight: false)
        }
        let (cpuUsageBreakdown, cpuCoreUsagePercent) = sampleCPUIfNeeded(enabledKinds: samplingKinds, now: now)
        let thermal = sampleThermalIfNeeded(
            enabledKinds: samplingKinds,
            thermalSamplingInterval: samplingPlan?.thermalInterval ?? thermalSamplingInterval,
            gpuSamplingInterval: samplingPlan?.gpuInterval ?? Self.gpuSamplingInterval,
            permitsStartupHardware: samplingPlan?.permitsStartupHardware ?? true,
            now: now
        )
        let sensorAvailability = sensorAvailability(
            enabledKinds: samplingKinds,
            thermal: thermal
        )
        let networkSample = samplingKinds.contains(.networkSpeed)
            ? MenuBarPresentationTrace.measureSample("network.counters") { SystemMonitorService.currentNetworkSample(now: now) }
            : previousNetworkSample

        let networkBaseline = wasNetworkSampling ? previousNetworkSample : nil
        wasNetworkSampling = samplingKinds.contains(.networkSpeed)
        let resolvedMemorySnapshot: MemorySnapshot?
        if samplingKinds.contains(.memoryUsage) {
            resolvedMemorySnapshot = resolvesMissingMemorySnapshot && memorySnapshot == nil
                ? await MemoryOptimizerService.statusSnapshot() : memorySnapshot
        } else {
            resolvedMemorySnapshot = nil
        }
        let bootAt = SystemMonitorService.measuredBootAt.flatMap { $0 <= now ? $0 : nil }

        return SystemMonitorService.buildSnapshot(
            enabledKinds: samplingKinds,
            memorySnapshot: resolvedMemorySnapshot,
            previousNetworkSample: samplingPlan == nil ? previousNetworkSample : networkBaseline,
            liveReadings: SystemMonitorService.LiveReadings(
                cpuUsagePercent: cpuUsageBreakdown?.totalPercent,
                cpuUsageBreakdown: cpuUsageBreakdown,
                cpuCoreUsagePercent: cpuCoreUsagePercent,
                loadAverage: SystemMonitorService.currentLoadAverage(),
                systemUptimeSeconds: bootAt.map {
                    max(0, now.timeIntervalSince($0))
                } ?? ProcessInfo.processInfo.systemUptime,
                systemBootAt: bootAt,
                thermalState: SystemMonitorService.currentThermalState(),
                thermal: thermal,
                sensorAvailability: sensorAvailability,
                fanAvailability: thermalSampledAt == nil
                    && (samplingKinds.contains(.fanSpeed) || samplingKinds.contains(.chipTemperature))
                    ? .sampling : .unavailable,
                networkSample: samplingKinds.contains(.networkSpeed) ? networkSample : nil
            ),
            sensorSampledAt: !samplingKinds.isDisjoint(with: [.chipTemperature, .fanSpeed]) ? thermalSampledAt : nil,
            gpuSampledAt: samplingKinds.contains(.gpuUsage) ? gpuSampledAt : nil,
            now: now
        )
    }

    /// One `host_processor_info` read serves both the per-core percentages and
    /// the aggregate breakdown: the kernel's aggregate counters are exactly the
    /// per-core sums, so a second `host_statistics` call per sample is only
    /// needed as a fallback when the per-core read fails.
    private func sampleCPUIfNeeded(
        enabledKinds: Set<MenuBarMetricKind>,
        now: Date
    ) -> (breakdown: CPUUsageBreakdown?, corePercents: [Double]?) {
        guard enabledKinds.contains(.cpuUsage) else {
            previousCPUTicks = nil
            previousCPUCoreTicks = nil
            previousCPUSampleAt = nil
            lastCPUBreakdown = nil
            lastCPUCorePercents = nil
            return (nil, nil)
        }
        // Two refreshes in one burst (open + timer) would divide a few ticks
        // by a near-zero interval. Keep the baseline and repeat the last
        // real interval instead, as the network delta does.
        if let previousCPUSampleAt, previousCPUTicks != nil,
           now >= previousCPUSampleAt,
           now.timeIntervalSince(previousCPUSampleAt) < Self.minimumCPUDeltaInterval {
            return (lastCPUBreakdown, lastCPUCorePercents)
        }

        let (coreTicks, totalTicks) = MenuBarPresentationTrace.measureSample("cpu") {
            cpuCounterReader()
        }

        var breakdown: CPUUsageBreakdown?
        if let totalTicks {
            breakdown = SystemMonitorService.cpuUsageBreakdown(
                current: totalTicks,
                previous: previousCPUTicks
            )
            previousCPUTicks = totalTicks
        }

        var corePercents: [Double]?
        if let coreTicks {
            corePercents = SystemMonitorService.cpuCoreUsagePercent(
                current: coreTicks,
                previous: previousCPUCoreTicks
            )
            previousCPUCoreTicks = coreTicks
        }
        previousCPUSampleAt = now
        lastCPUBreakdown = breakdown
        lastCPUCorePercents = corePercents

        return (breakdown, corePercents)
    }

    private static func totalTicks(
        fromCoreTicks coreTicks: [SystemMonitorService.CPUUsageTicks]
    ) -> SystemMonitorService.CPUUsageTicks {
        coreTicks.reduce(
            SystemMonitorService.CPUUsageTicks(user: 0, system: 0, idle: 0, nice: 0)
        ) { partial, ticks in
            SystemMonitorService.CPUUsageTicks(
                user: partial.user + ticks.user,
                system: partial.system + ticks.system,
                idle: partial.idle + ticks.idle,
                nice: partial.nice + ticks.nice
            )
        }
    }

    var activeHardwareReadCount: Int { (isGPUSampleInFlight ? 1 : 0) + (isThermalSampleInFlight ? 1 : 0) }

    private func sampleThermalIfNeeded(
        enabledKinds: Set<MenuBarMetricKind>,
        thermalSamplingInterval: TimeInterval,
        gpuSamplingInterval: TimeInterval,
        permitsStartupHardware: Bool,
        now: Date
    ) -> SystemMonitorService.ThermalReadings {
        // Not yet scheduled is still .sampling; no failed attempt or source date.
        guard permitsStartupHardware else { return cachedThermal }
        let gpuUsagePercent = sampleGPUIfNeeded(enabledKinds: enabledKinds, samplingInterval: gpuSamplingInterval, now: now)
        let thermal = sampleTemperatureAndFansIfNeeded(
            enabledKinds: enabledKinds,
            samplingInterval: thermalSamplingInterval,
            now: now
        )

        return SystemMonitorService.ThermalReadings(
            gpuUsagePercent: gpuUsagePercent,
            gpuMemoryUsedBytes: enabledKinds.contains(.gpuUsage) ? cachedGPUMemoryUsedBytes : nil,
            chipTemperatureCelsius: thermal.chipTemperatureCelsius,
            fanSpeedRPM: thermal.fanSpeedRPM,
            fanCount: thermal.fanCount,
            fanSpeedsRPM: thermal.fanSpeedsRPM,
            fanReadings: thermal.fanReadings,
            temperatureReadings: thermal.temperatureReadings,
            temperatureDetails: thermal.temperatureDetails,
            inferredTemperatureZones: thermal.inferredTemperatureZones,
            ambientLight: thermal.ambientLight
        )
    }

    private func sensorAvailability(
        enabledKinds: Set<MenuBarMetricKind>,
        thermal: SystemMonitorService.ThermalReadings
    ) -> SystemSensorAvailability {
        if thermal.hasAvailableSensorData { return .available }

        let gpuPending = enabledKinds.contains(.gpuUsage)
            && (isGPUSampleInFlight || gpuSampledAt == nil)
        let thermalPending = (
            enabledKinds.contains(.chipTemperature) || enabledKinds.contains(.fanSpeed)
        ) && (isThermalSampleInFlight || thermalSampledAt == nil)
        return gpuPending || thermalPending ? .sampling : .unavailable
    }

    private func sampleGPUIfNeeded(
        enabledKinds: Set<MenuBarMetricKind>,
        samplingInterval: TimeInterval,
        now: Date
    ) -> Double? {
        guard enabledKinds.contains(.gpuUsage) else { return nil }

        if let gpuSampledAt,
           now.timeIntervalSince(gpuSampledAt) < samplingInterval - 0.05 {
            return cachedGPUUsagePercent
        }

        if isGPUSampleInFlight {
            if !gpuSampleDidTimeOut,
               gpuSampleStartedAt.map({ now.timeIntervalSince($0) >= Self.gpuSampleTimeout }) ?? true {
                cachedGPUUsagePercent = nil
                cachedGPUMemoryUsedBytes = nil
                gpuSampleDidTimeOut = true
            }
            // The underlying driver call is synchronous and cannot be safely
            // cancelled. Keep a physical single-flight even after the display
            // watchdog expires so a stuck driver cannot create an unbounded
            // queue of detached tasks.
            return cachedGPUUsagePercent
        }

        gpuSampleGeneration &+= 1
        let generation = gpuSampleGeneration
        isGPUSampleInFlight = true
        gpuSampleStartedAt = now
        gpuSampleDidTimeOut = false
        let reader = gpuReader
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = MenuBarPresentationTrace.measureSample("gpu.registry") { reader() }
            await self?.finishGPUSample(
                usagePercent: snapshot?.usagePercent,
                memoryUsedBytes: snapshot?.memoryUsedBytes,
                generation: generation,
                sampledAt: now
            )
        }
        return cachedGPUUsagePercent
    }

    private func sampleTemperatureAndFansIfNeeded(
        enabledKinds: Set<MenuBarMetricKind>,
        samplingInterval: TimeInterval,
        now: Date
    ) -> SystemMonitorService.ThermalReadings {
        let needsThermal = enabledKinds.contains(.chipTemperature)
            || enabledKinds.contains(.fanSpeed)
        guard needsThermal else { return .empty }

        if let thermalSampledAt,
           now.timeIntervalSince(thermalSampledAt) < max(1, samplingInterval) {
            return cachedThermal
        }

        if isThermalSampleInFlight {
            if !thermalSampleDidTimeOut,
               thermalSampleStartedAt.map({ now.timeIntervalSince($0) >= Self.thermalSampleTimeout }) ?? true {
                // Keep the last coherent temperatures visible while the
                // physical single-flight finishes. Clearing here made every
                // transiently slow SMC pass flash the whole sensor list to —.
                thermalSampleDidTimeOut = true
            }
            return cachedThermal
        }

        thermalSampleGeneration &+= 1
        let generation = thermalSampleGeneration
        isThermalSampleInFlight = true
        thermalSampleStartedAt = now
        thermalSampleDidTimeOut = false
        let reader = temperatureAndFanReader
        Task.detached(priority: .utility) { [weak self] in
            let readings = MenuBarPresentationTrace.measureSample("sensors.smc-hid") { reader() }
            await self?.finishThermalSample(
                readings,
                generation: generation,
                sampledAt: now
            )
        }
        return cachedThermal
    }

    private func clearGPUCache(discardInFlight: Bool = true) {
        cachedGPUUsagePercent = nil
        cachedGPUMemoryUsedBytes = nil
        gpuSampledAt = nil
        if discardInFlight, isGPUSampleInFlight { discardsGPUInFlight = true }
    }

    private func clearThermalCache(discardInFlight: Bool = true) {
        cachedThermal = .empty
        thermalSampledAt = nil
        if discardInFlight, isThermalSampleInFlight { discardsThermalInFlight = true }
    }

    private func finishGPUSample(
        usagePercent: Double?,
        memoryUsedBytes: Int64?,
        generation: UInt64,
        sampledAt: Date
    ) {
        guard generation == gpuSampleGeneration else { return }
        if discardsGPUInFlight {
            discardsGPUInFlight = false
            isGPUSampleInFlight = false
            gpuSampleStartedAt = nil
            gpuSampleDidTimeOut = false
            return
        }
        cachedGPUUsagePercent = usagePercent
        cachedGPUMemoryUsedBytes = memoryUsedBytes
        gpuSampledAt = sampledAt
        isGPUSampleInFlight = false
        gpuSampleStartedAt = nil
        gpuSampleDidTimeOut = false
    }

    private func finishThermalSample(
        _ readings: SystemMonitorService.ThermalReadings,
        generation: UInt64,
        sampledAt: Date
    ) {
        guard generation == thermalSampleGeneration else { return }
        if discardsThermalInFlight {
            discardsThermalInFlight = false
            isThermalSampleInFlight = false
            thermalSampleStartedAt = nil
            thermalSampleDidTimeOut = false
            return
        }
        cachedThermal = readings
        thermalSampledAt = sampledAt
        isThermalSampleInFlight = false
        thermalSampleStartedAt = nil
        thermalSampleDidTimeOut = false
    }
}
