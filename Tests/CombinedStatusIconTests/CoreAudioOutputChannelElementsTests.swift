// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/CoreAudioOutputChannelElementsTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import CoreAudio
import XCTest

@testable import CombinedStatusIcon

final class CoreAudioOutputChannelElementsTests: XCTestCase {
    func testMissingOrZeroChannelCountFallsBackToFirstTwoChannels() {
        XCTAssertEqual(CoreAudioOutputChannelElements.channels(forChannelCount: nil), [1, 2])
        XCTAssertEqual(CoreAudioOutputChannelElements.channels(forChannelCount: 0), [1, 2])
    }

    func testChannelCountProducesAllOneBasedElements() {
        XCTAssertEqual(CoreAudioOutputChannelElements.channels(forChannelCount: 4), [1, 2, 3, 4])
    }
}
