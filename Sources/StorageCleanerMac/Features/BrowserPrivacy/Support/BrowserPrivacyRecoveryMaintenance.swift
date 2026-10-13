import Foundation

/// Removes recovery backups whose retention period has ended (D26: seven
/// days). From launch on it checks again whenever the next backup expires
/// (at least once an hour), and once more whenever the browser privacy page
/// opens.
@MainActor
enum BrowserPrivacyRecoveryMaintenance {
    /// Off until the app has launched, so a view that a test renders never
    /// touches the user's Application Support folder.
    private(set) static var isEnabled = false
    private static var scheduledChecks: Task<Void, Never>?

    /// Called once the app has launched: removes what has expired now and
    /// keeps doing so for as long as the app runs.
    static func enableAndPurge() {
        isEnabled = true
        guard scheduledChecks == nil else { return }
        let loop = BrowserPrivacyRecoveryPurgeLoop(
            service: BrowserPrivacyRecoveryBackupService(),
            now: { Date() },
            sleep: { seconds in
                // The continuous clock keeps counting while the Mac sleeps,
                // so an expiry that passes during sleep is handled on waking.
                try await ContinuousClock().sleep(for: .seconds(seconds), tolerance: .seconds(10))
            }
        )
        scheduledChecks = Task.detached(priority: .utility) {
            await loop.run()
        }
    }

    static func purgeIfEnabled() {
        guard isEnabled else { return }
        Task.detached(priority: .utility) {
            BrowserPrivacyRecoveryBackupService().purgeExpired()
        }
    }
}

/// When the next look for expired backups is due while the app keeps
/// running: just after the earliest backup expires, but never more than an
/// hour away, so a backup taken in the meantime, a changed system clock or a
/// long sleep is noticed within the hour.
enum BrowserPrivacyRecoveryPurgeSchedule {
    static let maximumWait: TimeInterval = 3_600
    /// Wake just after the expiry rather than just before it.
    static let slack: TimeInterval = 1

    static func wait(
        untilEarliestExpiry expiry: Date?,
        now: Date,
        maximumWait: TimeInterval = maximumWait
    ) -> TimeInterval {
        // Nothing left, or a backup that has expired but could not be
        // removed: look again later rather than in a tight loop.
        guard let expiry, expiry > now else { return maximumWait }
        return min(expiry.timeIntervalSince(now) + slack, maximumWait)
    }
}

/// Removes expired backups for as long as it runs. The clock and the wait
/// are injected so tests can run days in a moment.
struct BrowserPrivacyRecoveryPurgeLoop: Sendable {
    let service: BrowserPrivacyRecoveryBackupService
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    var maximumWait: TimeInterval = BrowserPrivacyRecoveryPurgeSchedule.maximumWait

    /// Purges, waits until the next backup expires (at most `maximumWait`)
    /// and repeats until the task is cancelled or `sleep` throws.
    func run() async {
        while !Task.isCancelled {
            let current = now()
            service.purgeExpired(now: current)
            let wait = BrowserPrivacyRecoveryPurgeSchedule.wait(
                untilEarliestExpiry: service.earliestExpiry(),
                now: current,
                maximumWait: maximumWait
            )
            do {
                try await sleep(wait)
            } catch {
                return
            }
        }
    }
}
