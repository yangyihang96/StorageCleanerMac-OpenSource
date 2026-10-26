// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Audio/CoreAudioOutputChannelElements.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import CoreAudio

enum CoreAudioOutputChannelElements {
    nonisolated static func channels(for deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        for _ in 0..<3 {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var requestedSize: UInt32 = 0

            guard AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &requestedSize
            ) == noErr,
                  requestedSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
                continue
            }

            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: Int(requestedSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { storage.deallocate() }

            let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
            var returnedSize = requestedSize
            guard AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &returnedSize,
                bufferList
            ) == noErr,
                  returnedSize <= requestedSize else {
                continue
            }

            let channelCount = UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
                $0 + Int($1.mNumberChannels)
            }
            return channels(forChannelCount: channelCount)
        }

        return channels(forChannelCount: nil)
    }

    nonisolated static func channels(forChannelCount count: Int?) -> [AudioObjectPropertyElement] {
        guard let count, count > 0 else { return [1, 2] }
        return (1...count).map(AudioObjectPropertyElement.init)
    }

    nonisolated static func all(for deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain] + channels(for: deviceID)
    }
}
