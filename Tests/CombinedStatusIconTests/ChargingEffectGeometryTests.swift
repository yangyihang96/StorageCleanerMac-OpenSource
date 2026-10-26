// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/ChargingEffectGeometryTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import CoreGraphics
import Testing
@testable import CombinedStatusIcon

struct ChargingEffectGeometryTests {
    @Test func visibleArcMappingRoundTripsOnBothSidesOfTheTopGap() {
        let progressValues = [0.0, 0.1, 0.2, 0.385, 0.615, 0.8, 0.9, 1.0]

        for progress in progressValues {
            let visible = StatusIconGeometry.visibleFraction(
                forProgress: progress,
                hasTopGap: true,
                topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
            )
            let roundTrip = StatusIconGeometry.progress(
                forVisibleFraction: visible,
                hasTopGap: true,
                topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
            )

            #expect(abs(roundTrip - progress) < 1e-9)
        }
    }

    @Test func visibleFractionPreservesVisibleArcLengthCoordinates() {
        let beforeGap = StatusIconGeometry.visibleFraction(
            forProgress: 0.2,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        )
        let afterGap = StatusIconGeometry.visibleFraction(
            forProgress: 0.8,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        )
        let insideGap = StatusIconGeometry.visibleFraction(
            forProgress: 0.5,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        )

        #expect(abs(beforeGap - 0.2) < 1e-9)
        #expect(abs(afterGap - 0.5707) < 0.001)
        #expect(abs(insideGap - 0.3854) < 0.001)
    }

    @Test func intervalHighlightSplitsAroundGapButNotOnAContinuousArc() {
        let split = StatusIconGeometry.batteryHighlight(
            from: 0.2,
            to: 0.8,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        )
        let continuous = StatusIconGeometry.batteryHighlight(
            from: 0.2,
            to: 0.8,
            hasTopGap: false
        )

        #expect(moveToCount(in: split) == 2)
        #expect(moveToCount(in: continuous) == 1)
    }

    @Test func fillEndpointInsideGapStopsAtTheLeftGapEdge() {
        let lastVisible = StatusIconGeometry.lastVisibleProgress(
            forProgress: 0.5,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        )

        #expect(abs(lastVisible - 0.3854) < 0.001)
    }

    @Test func invalidAndEmptyIntervalsProduceEmptyPaths() {
        let nan = StatusIconGeometry.batteryHighlight(
            from: .nan,
            to: 0.8,
            hasTopGap: true
        )
        let infinite = StatusIconGeometry.batteryHighlight(
            from: 0.2,
            to: .infinity,
            hasTopGap: true
        )
        let inverted = StatusIconGeometry.batteryHighlight(
            from: 0.8,
            to: 0.2,
            hasTopGap: true
        )
        let zeroLength = StatusIconGeometry.batteryHighlight(
            from: 0.4,
            to: 0.4,
            hasTopGap: false
        )

        #expect(nan.isEmpty)
        #expect(infinite.isEmpty)
        #expect(inverted.isEmpty)
        #expect(zeroLength.isEmpty)
    }

    @Test func noGapVisibleMappingIsIdentityAndClampsProgress() {
        #expect(StatusIconGeometry.visibleFraction(forProgress: 0.37, hasTopGap: false) == 0.37)
        #expect(StatusIconGeometry.progress(forVisibleFraction: 0.63, hasTopGap: false) == 0.63)
        #expect(StatusIconGeometry.visibleFraction(forProgress: 2, hasTopGap: false) == 1)
        #expect(StatusIconGeometry.visibleFraction(forProgress: -1, hasTopGap: false) == 0)
    }

    private func moveToCount(in path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint {
                count += 1
            }
        }
        return count
    }
}
