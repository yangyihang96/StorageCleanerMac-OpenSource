// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Presentation/Icon/CenterState.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

enum CenterState: Equatable, Hashable, Sendable {
    case symbol(IconSymbolState)
    case text(IconTextState)
}
