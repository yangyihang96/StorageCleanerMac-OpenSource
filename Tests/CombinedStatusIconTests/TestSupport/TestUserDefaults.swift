// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/TestUserDefaults.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import Foundation

/// Test-only helpers for discarding the isolated `UserDefaults` suites that
/// tests create.
///
/// The name-only entry point exists so teardown blocks can discard a suite
/// without capturing a `UserDefaults` instance, which is not `Sendable` and so
/// cannot be captured by an `@Sendable` teardown closure under Swift 6 strict
/// concurrency.
enum TestUserDefaults {
    /// Location of the plist `UserDefaults` persists a suite named `name` into.
    static func fileURL(forSuite name: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(name).plist")
    }

    /// Removes an isolated test suite.
    ///
    /// The backing `~/Library/Preferences/<name>.plist` is what has to go:
    /// `removePersistentDomain(forName:)` leaves the domain alive inside
    /// cfprefsd, which then flushes it back to disk as an empty 42-byte plist a
    /// second or two later. Deleting the file after that write-back loses the
    /// race, and every run used to leave one dead plist per suite behind
    /// forever — 53 051 of them had piled up in `~/Library/Preferences` by the
    /// time this was measured. Deleting the file without touching the domain is
    /// what fixes it: a full test run went from about one file per suite to
    /// about a hundred files (measured 103), because cfprefsd's flush of a
    /// domain it had already queued can still land after the removal.
    ///
    /// Closing that last gap needs a sweep after the run, or an isolation
    /// mechanism other than a `UserDefaults` suite; both are broader changes
    /// than this teardown.
    static func removeSuite(named name: String) {
        try? FileManager.default.removeItem(at: fileURL(forSuite: name))
    }
}

extension UserDefaults {
    /// Convenience form of `TestUserDefaults.removeSuite(named:)` for call sites
    /// that already hold the suite.
    func removeTestSuite(named name: String) {
        TestUserDefaults.removeSuite(named: name)
    }
}
