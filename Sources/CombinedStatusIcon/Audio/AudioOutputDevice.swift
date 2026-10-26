// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Audio/AudioOutputDevice.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): made public what the app reads.

import CoreAudio

public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String?
    let uid: String?
    let isCurrent: Bool
    let volume: Double?
    /// The hardware family of the device, read from
    /// `kAudioDevicePropertyTransportType`.
    let transport: AudioOutputTransport?
    /// The live output data source, read from `kAudioDevicePropertyDataSource`.
    let dataSource: AudioOutputDataSource?
    /// The icon the driver ships for the device, read from
    /// `kAudioDevicePropertyIcon`. Built-in hardware has no icon.
    let iconURL: URL?
    /// The device's model identifier, read from `kAudioDevicePropertyModelUID`.
    /// A Bluetooth device reports its product and vendor IDs here ("200f 4c"),
    /// which is what identifies an AirPods model even after a rename.
    let modelUID: String?

    init(
        id: AudioDeviceID,
        name: String?,
        uid: String? = nil,
        isCurrent: Bool,
        volume: Double? = nil,
        transport: AudioOutputTransport? = nil,
        dataSource: AudioOutputDataSource? = nil,
        iconURL: URL? = nil,
        modelUID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.uid = uid
        self.isCurrent = isCurrent
        self.volume = volume
        self.transport = transport
        self.dataSource = dataSource
        self.iconURL = iconURL
        self.modelUID = modelUID
    }

    public var isBluetoothAudio: Bool {
        transport?.isBluetooth == true
    }

    func replacingVolume(_ volume: Double?) -> AudioOutputDevice {
        AudioOutputDevice(id: id, name: name, uid: uid, isCurrent: isCurrent, volume: volume,
                          transport: transport, dataSource: dataSource, iconURL: iconURL, modelUID: modelUID)
    }
}
