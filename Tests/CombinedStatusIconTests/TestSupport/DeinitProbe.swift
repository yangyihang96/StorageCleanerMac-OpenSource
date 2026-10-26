// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/DeinitProbe.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import Foundation

/// Holds a weak reference so a test can assert that an object deallocated.
///
/// This exists because `AGENTS.md` requires weak reference bindings to be
/// `var` (see docs/swift-ci-compatibility.md, run 34753843803), while the
/// compiler warns about a `weak var` local that is only ever read. A weak `var`
/// stored property satisfies both: the rule keeps its exact spelling, and the
/// diagnostic goes away without weakening any test.
final class DeinitProbeRef<T: AnyObject> {
    weak var value: T?

    init(_ object: T?) {
        value = object
    }
}

enum DeinitProbe {
    /// - Parameter object: the strong reference to observe. Pass the variable
    ///   itself, then set that variable to nil and read `probe.value`.
    /// - Returns: a probe that must outlive the read of `probe.value`. Keep the
    ///   result bound to a local for the whole assertion; a probe that is
    ///   released before the read leaves nothing to observe. The result is
    ///   deliberately not `@discardableResult` so the compiler rejects a call
    ///   site that drops the probe and its deallocation assertion with it.
    static func track<T: AnyObject>(_ object: T?) -> DeinitProbeRef<T> {
        DeinitProbeRef(object)
    }
}
