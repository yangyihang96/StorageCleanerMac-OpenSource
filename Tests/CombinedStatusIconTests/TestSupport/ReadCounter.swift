// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/ReadCounter.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import Foundation

/// Thread-safe call counter for closures that run off the main actor.
final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increments and returns the new value, so callers can number their calls.
    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var calls: Int { lock.withLock { count } }
}
