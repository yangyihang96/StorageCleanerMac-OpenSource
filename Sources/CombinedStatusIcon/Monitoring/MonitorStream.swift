// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Monitoring/MonitorStream.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

enum MonitorStream {
    static func make<Element>(
        of type: Element.Type
    ) -> (AsyncStream<Element>, AsyncStream<Element>.Continuation) {
        AsyncStream.makeStream(
            of: type,
            bufferingPolicy: .bufferingNewest(1)
        )
    }
}
