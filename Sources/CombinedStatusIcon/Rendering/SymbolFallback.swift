// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/UI/SymbolFallback.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import AppKit

/// Resolves SF Symbols against the running macOS release.
///
/// Several symbols used by the app were introduced after Ventura. A missing
/// symbol is not a rendering failure on a newer host, so every call site that
/// can draw a dynamic or versioned glyph goes through this resolver.
enum SymbolFallback {
    static func name(_ preferred: String, _ fallbacks: String...) -> String {
        name(preferred, fallbacks)
    }

    static func name(_ preferred: String, _ fallbacks: [String]) -> String {
        name(preferred, fallbacks, isAvailable: isAvailable)
    }

    static func name(
        _ preferred: String,
        _ fallbacks: [String],
        isAvailable: (String) -> Bool
    ) -> String {
        let candidates = [preferred] + fallbacks
        return candidates.first(where: isAvailable) ?? candidates.last ?? "questionmark.circle"
    }

    static func isAvailable(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
