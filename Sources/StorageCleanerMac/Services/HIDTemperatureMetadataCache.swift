import Foundation

/// A service identity must remain unique while retained in the metadata cache.
/// The production identity owns its CF service object to prevent address reuse.
protocol HIDTemperatureReadingDriver: AnyObject {
    associatedtype Service
    associatedtype Identity: Hashable

    func services() -> [Service]?
    func identity(of service: Service) -> Identity
    func rawIdentifier(of service: Service) -> String?
    func name(of service: Service) -> String?
    func temperature(of service: Service) -> Double?
}

extension HIDTemperatureReadingDriver {
    func rawIdentifier(of service: Service) -> String? { nil }
}

/// Owned by the serialized TemperatureClient. Only identities/names survive a
/// pass. Every pass obtains the full current graph and fresh temperature events;
/// cached service handles are never used to read a subsequent pass.
final class HIDTemperatureMetadataCache<Driver: HIDTemperatureReadingDriver> {
    private let driver: Driver
    private var graph: Set<Driver.Identity> = []
    private var names: [Driver.Identity: String] = [:]
    private var channels: [Driver.Identity: (rawID: String, ordinal: Int)] = [:]
    private var nextOrdinal = 0
    private let connectionID = UUID().uuidString


    init(driver: Driver) { self.driver = driver }

    func readings(now: Date = Date()) -> [AppleSiliconTemperatureService.Reading]? {
        guard let services = driver.services() else {
            graph.removeAll()
            names.removeAll()
            channels.removeAll()
            return nil
        }
        let identities = services.map { driver.identity(of: $0) }
        let currentGraph = Set(identities)
        if currentGraph != graph {
            names.removeAll(keepingCapacity: true)
            channels = channels.filter { currentGraph.contains($0.key) }
            graph = currentGraph
        }

        var readings: [AppleSiliconTemperatureService.Reading] = []
        for (service, identity) in zip(services, identities) {
            if channels[identity] == nil {
                nextOrdinal += 1
                channels[identity] = (driver.rawIdentifier(of: service) ?? "connection-\(connectionID)", nextOrdinal)
            }
            guard let rawValue = driver.temperature(of: service) else { continue }
            let name: String
            if let cached = names[identity] {
                name = cached
            } else if let resolved = driver.name(of: service) {
                names[identity] = resolved
                name = resolved
            } else {
                // A temporarily missing Product property is retried next pass.
                name = ""
            }
            guard let value = AppleSiliconTemperatureService.normalizedTemperature(rawValue: rawValue, sensorName: name) else {
                continue
            }
            if let channel = channels[identity] {
                readings.append(.init(name: name, value: value, serviceID: channel.rawID,
                                      ordinal: channel.ordinal, sampledAt: now))
            }
        }
        return readings
    }
}
