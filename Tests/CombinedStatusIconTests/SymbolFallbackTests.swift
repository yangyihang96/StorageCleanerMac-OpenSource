// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/SymbolFallbackTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import XCTest
@testable import CombinedStatusIcon

final class SymbolFallbackTests: XCTestCase {
    func testUnavailableBatterySymbolFallsBackToVenturaName() {
        XCTAssertEqual(
            SymbolFallback.name(
                "battery.100percent",
                ["battery.100"],
                isAvailable: { $0 == "battery.100" }
            ),
            "battery.100"
        )
    }

    func testUnavailableAirPodsGenerationFallsBackToFamilySymbol() {
        XCTAssertEqual(
            SymbolFallback.name(
                "airpods.pro.gen3",
                ["airpods.pro", "airpodspro", "headphones"],
                isAvailable: { $0 == "airpods" || $0 == "headphones" }
            ),
            "headphones"
        )
    }

    func testVenturaMissingSymbolFamiliesHaveStableFallbacks() {
        let unavailable: Set<String> = [
            "battery.100percent",
            "battery.75percent",
            "flask.fill",
            "powerplug.portrait.fill",
            "watch.analog",
            "airpods.gen4",
            "airpods.pro",
            "airpods.max",
            "beats.pill",
            "beats.solobuds",
            "beats.studiobuds.plus",
            "beats.fitpro",
            "beats.powerbeats.pro.2",
            "homepod.mini",
            "macbook",
            "macmini.gen2",
            "translate"
        ]
        let checks: [(String, [String])] = [
            ("battery.100percent", ["battery.100"]),
            ("battery.75percent", ["battery.75"]),
            ("flask.fill", ["testtube.2"]),
            ("powerplug.portrait.fill", ["powerplug.fill", "bolt.fill"]),
            ("translate", ["character.bubble", "globe"]),
            ("watch.analog", ["applewatch", "clock"]),
            ("airpods.gen4", ["airpods", "headphones"]),
            ("airpods.pro", ["airpodspro", "headphones"]),
            ("airpods.max", ["headphones"]),
            ("beats.pill", ["beats.headphones", "headphones"]),
            ("beats.solobuds", ["beats.headphones", "headphones"]),
            ("beats.studiobuds.plus", ["beats.headphones", "headphones"]),
            ("beats.fitpro", ["beats.headphones", "headphones"]),
            ("beats.powerbeats.pro.2", ["beats.headphones", "headphones"]),
            ("homepod.mini", ["homepod", "hifispeaker.fill"]),
            ("macbook", ["desktopcomputer"]),
            ("macmini.gen2", ["macmini", "desktopcomputer"])
        ]

        for (preferred, fallbacks) in checks {
            let resolved = SymbolFallback.name(
                preferred,
                fallbacks,
                isAvailable: { !unavailable.contains($0) }
            )
            XCTAssertNotEqual(resolved, preferred, "\(preferred) must fall back on Ventura")
            XCTAssertFalse(
                unavailable.contains(resolved),
                "\(preferred) resolved to an unavailable Ventura symbol: \(resolved)"
            )
        }
    }

    func testNoAvailableCandidateUsesLastStableFallback() {
        XCTAssertEqual(
            SymbolFallback.name(
                "airpods.gen5",
                ["airpods", "headphones"],
                isAvailable: { _ in false }
            ),
            "headphones"
        )
    }
}
