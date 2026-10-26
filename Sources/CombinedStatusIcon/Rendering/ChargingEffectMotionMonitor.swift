// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/App/ChargingEffectMotionMonitor.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import AppKit
import Foundation

@MainActor
final class ChargingEffectMotionMonitor {
    static let didChangeNotification = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification

    private let readReduceMotion: () -> Bool
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    private(set) var shouldReduceMotion: Bool
    var onChange: ((Bool) -> Void)?

    init(
        readReduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.readReduceMotion = readReduceMotion
        self.notificationCenter = notificationCenter
        self.shouldReduceMotion = readReduceMotion()
    }

    func start() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: Self.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    func refresh() {
        let currentValue = readReduceMotion()
        guard currentValue != shouldReduceMotion else { return }
        shouldReduceMotion = currentValue
        onChange?(currentValue)
    }
}
