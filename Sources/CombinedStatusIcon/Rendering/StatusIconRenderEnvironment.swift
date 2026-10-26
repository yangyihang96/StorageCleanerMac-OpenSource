// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/UI/Icon/StatusIconRenderEnvironment.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import CoreGraphics

struct StatusIconRenderEnvironment {
    let size: CGFloat
    let scale: CGFloat
    let foreground: CGColor
    let criticalColor: CGColor
}
