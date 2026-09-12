import Combine
import FanControlShared
import Foundation
import os

@MainActor
final class FanCurveStore: ObservableObject {
    @Published private(set) var savedProfile: FanCurveProfile
    @Published private(set) var draftProfile: FanCurveProfile
    @Published private(set) var appliedProfile: FanCurveProfile?
    @Published private(set) var validationError: FanCurveError?

    private enum Keys {
        static let savedProfile = "fanCurve.savedProfile.v1"
        static let draftProfile = "fanCurve.draftProfile.v1"
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private static let logger = Logger(
        subsystem: StorageCleanerBuildIdentity.appBundleIdentifier,
        category: "FanCurveStore"
    )

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.now = now
        let fallback = FanCurveProfile.balanced(now: now())
        let loadedSavedProfile = Self.loadProfile(
            defaults: defaults,
            key: Keys.savedProfile,
            fallback: fallback
        )
        let loadedDraftProfile = Self.loadProfile(
            defaults: defaults,
            key: Keys.draftProfile,
            fallback: loadedSavedProfile
        )
        savedProfile = loadedSavedProfile
        draftProfile = loadedDraftProfile
        validationError = Self.validationError(for: loadedDraftProfile)
    }

    var hasUnappliedChanges: Bool {
        !draftProfile.hasSameControlDefinition(as: appliedProfile)
    }

    var hasUnsavedDraftChanges: Bool {
        !draftProfile.hasSameControlDefinition(as: savedProfile)
    }

    func setSensor(_ sensor: FanCurveSensor) {
        updateDraft { $0.sensor = sensor }
    }

    func updatePoint(
        id: UUID,
        temperatureCelsius: Double,
        speedFraction: Double
    ) {
        guard temperatureCelsius.isFinite,
              speedFraction.isFinite,
              let index = draftProfile.points.firstIndex(where: { $0.id == id }) else {
            return
        }
        var points = draftProfile.points
        let isLast = index == points.indices.last
        let lowerTemperature = index > 0
            ? points[index - 1].temperatureCelsius + FanCurveProfile.minimumTemperatureGap
            : FanCurveProfile.temperatureRange.lowerBound
        let upperTemperature = isLast
            ? FanCurveProfile.latestFullSpeedTemperature
            : points[index + 1].temperatureCelsius - FanCurveProfile.minimumTemperatureGap
        let lowerFraction = index > 0 ? points[index - 1].speedFraction : 0
        let upperFraction = isLast ? 1 : points[index + 1].speedFraction
        points[index].temperatureCelsius = min(
            upperTemperature,
            max(lowerTemperature, temperatureCelsius.rounded())
        )
        points[index].speedFraction = isLast
            ? 1
            : min(upperFraction, max(lowerFraction, speedFraction))
        updateDraft { $0.points = points }
    }

    func addPoint() {
        let points = draftProfile.points
        guard points.count < FanCurveProfile.maximumPointCount else { return }
        let gaps = zip(points.indices, points.indices.dropFirst()).map { lower, upper in
            (lower: lower, upper: upper, gap: points[upper].temperatureCelsius - points[lower].temperatureCelsius)
        }
        guard let largest = gaps.max(by: { $0.gap < $1.gap }),
              largest.gap >= FanCurveProfile.minimumTemperatureGap * 2 else { return }
        let lower = points[largest.lower]
        let upper = points[largest.upper]
        let point = FanCurvePoint(
            temperatureCelsius: ((lower.temperatureCelsius + upper.temperatureCelsius) / 2).rounded(),
            speedFraction: (lower.speedFraction + upper.speedFraction) / 2
        )
        var updated = points
        updated.insert(point, at: largest.upper)
        updateDraft { $0.points = updated }
    }

    func removePoint(id: UUID) {
        guard draftProfile.points.count > FanCurveProfile.minimumPointCount,
              let index = draftProfile.points.firstIndex(where: { $0.id == id }),
              index != draftProfile.points.indices.last else { return }
        updateDraft { $0.points.remove(at: index) }
    }

    func restoreDefault() {
        var profile = FanCurveProfile.balanced(now: now())
        profile.id = draftProfile.id
        profile.name = draftProfile.name
        updateDraft { $0 = profile }
    }

    func discardDraft() {
        draftProfile = savedProfile
        validationError = Self.validationError(for: draftProfile)
        persist(draftProfile, key: Keys.draftProfile)
    }

    func preparedProfile(targetFanIDs: [Int]) throws -> FanCurveProfile {
        let prepared = draftProfile.replacingTargetFanIDs(targetFanIDs, now: now())
        try FanCurveValidator.validate(prepared, requiresTargetFans: true)
        return prepared
    }

    /// Commits one completed editor action. Pointer-move updates stay in the
    /// editor session and never reach persistence through this method.
    @discardableResult
    func replaceDraft(_ profile: FanCurveProfile) -> Bool {
        var candidate = profile
        candidate.updatedAt = now()
        guard let error = Self.validationError(for: candidate) else {
            validationError = nil
            guard !candidate.hasSameControlDefinition(as: draftProfile) else { return true }
            draftProfile = candidate
            persist(candidate, key: Keys.draftProfile)
            return true
        }
        validationError = error
        return false
    }

    func markApplied(_ profile: FanCurveProfile) {
        savedProfile = profile
        draftProfile = profile
        appliedProfile = profile
        validationError = nil
        persist(profile, key: Keys.savedProfile)
        persist(profile, key: Keys.draftProfile)
    }

    func clearAppliedProfile() {
        appliedProfile = nil
    }

    private func updateDraft(_ update: (inout FanCurveProfile) -> Void) {
        var candidate = draftProfile
        update(&candidate)
        candidate.updatedAt = now()
        guard Self.validationError(for: candidate) == nil else { return }
        draftProfile = candidate
        validationError = nil
        persist(candidate, key: Keys.draftProfile)
    }

    private func persist(_ profile: FanCurveProfile, key: String) {
        do {
            defaults.set(try JSONEncoder().encode(profile), forKey: key)
        } catch {
            Self.logger.error("Could not persist fan curve: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadProfile(
        defaults: UserDefaults,
        key: String,
        fallback: FanCurveProfile
    ) -> FanCurveProfile {
        guard let data = defaults.data(forKey: key) else { return fallback }
        do {
            let profile = try JSONDecoder().decode(FanCurveProfile.self, from: data)
            try FanCurveValidator.validate(profile)
            return profile
        } catch {
            logger.error("Discarded corrupt fan curve: \(error.localizedDescription, privacy: .public)")
            return fallback
        }
    }

    private static func validationError(for profile: FanCurveProfile) -> FanCurveError? {
        do {
            try FanCurveValidator.validate(profile)
            return nil
        } catch let error as FanCurveError {
            return error
        } catch {
            return .curveActivationFailed
        }
    }
}
