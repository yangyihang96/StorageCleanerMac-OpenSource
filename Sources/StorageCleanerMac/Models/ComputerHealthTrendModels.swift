import Foundation

struct StoragePressureForecast: Codable, Equatable, Sendable {
    static let currentModelVersion = "storage-pressure-v1"

    let dailyAvailableByteSlope: Double
    let slopeMAD: Double
    let pressureLineBytes: Int64
    let daysUntilPressure: Int
    let earliestDaysUntilPressure: Int?
    let latestDaysUntilPressure: Int?
    let sampleCount: Int
    let spanDays: Int
    let evaluatedAt: Date
    let modelVersion: String

    init(
        dailyAvailableByteSlope: Double,
        slopeMAD: Double,
        pressureLineBytes: Int64,
        daysUntilPressure: Int,
        earliestDaysUntilPressure: Int? = nil,
        latestDaysUntilPressure: Int? = nil,
        sampleCount: Int,
        spanDays: Int,
        evaluatedAt: Date,
        modelVersion: String = StoragePressureForecast.currentModelVersion
    ) {
        self.dailyAvailableByteSlope = dailyAvailableByteSlope
        self.slopeMAD = slopeMAD
        self.pressureLineBytes = pressureLineBytes
        self.daysUntilPressure = daysUntilPressure
        self.earliestDaysUntilPressure = earliestDaysUntilPressure
        self.latestDaysUntilPressure = latestDaysUntilPressure
        self.sampleCount = sampleCount
        self.spanDays = spanDays
        self.evaluatedAt = evaluatedAt
        self.modelVersion = modelVersion
    }
}

enum BatteryWearTrendClassification: String, Codable, Equatable, Sendable {
    case stable
    case observe
    case decliningQuickly
}

struct BatteryWearTrend: Codable, Equatable, Sendable {
    static let currentModelVersion = "battery-wear-v1"

    let lossPer90Days: Double
    let lossPer100Cycles: Double?
    let capacityMAD: Double
    let confidence: Int
    let classification: BatteryWearTrendClassification
    let sampleCount: Int
    let spanDays: Int
    let evaluatedAt: Date
    let modelVersion: String

    init(
        lossPer90Days: Double,
        lossPer100Cycles: Double?,
        capacityMAD: Double,
        confidence: Int,
        classification: BatteryWearTrendClassification,
        sampleCount: Int,
        spanDays: Int,
        evaluatedAt: Date,
        modelVersion: String = BatteryWearTrend.currentModelVersion
    ) {
        self.lossPer90Days = lossPer90Days
        self.lossPer100Cycles = lossPer100Cycles
        self.capacityMAD = capacityMAD
        self.confidence = confidence
        self.classification = classification
        self.sampleCount = sampleCount
        self.spanDays = spanDays
        self.evaluatedAt = evaluatedAt
        self.modelVersion = modelVersion
    }
}
