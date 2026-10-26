// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Monitoring/VolumeMonitor.swift (lines 1-813)
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): the reading, client and listener types only (lines 1-813); the monitor that also drives DDC display volume is replaced by CombinedStatusVolumeMonitor. Logs under this app's subsystem.

import AppKit
import CoreAudio
import Foundation
import os

private let volumeMonitorLogger = Logger(
    subsystem: "com.local.StorageCleanerMac",
    category: "CombinedStatusIcon.VolumeMonitor"
)

struct VolumeReading: Equatable, Sendable {
    let scalar: Double?
    let isMuted: Bool
    let deviceName: String?
    let currentDevice: AudioOutputDevice?
    let canSetVolume: Bool
    let canMute: Bool

    init(
        scalar: Double?,
        isMuted: Bool,
        deviceName: String?,
        currentDevice: AudioOutputDevice? = nil,
        canSetVolume: Bool? = nil,
        canMute: Bool? = nil
    ) {
        self.scalar = scalar
        self.isMuted = isMuted
        self.deviceName = deviceName
        self.currentDevice = currentDevice
        self.canSetVolume = canSetVolume ?? (scalar != nil)
        self.canMute = canMute ?? (scalar != nil)
    }
}

protocol VolumeReadingProviding: AnyObject {
    func read() -> VolumeReading?
}

protocol CoreAudioClient: AnyObject {
    func defaultOutputDevice() -> AudioDeviceID?
    func outputChannelElements(deviceID: AudioDeviceID) -> [AudioObjectPropertyElement]
    func deviceClass(of deviceID: AudioDeviceID) -> AudioClassID?
    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool

    func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32?

    func readFloat32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32?

    func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> String?

    func readURL(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> URL?

    func hasProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool
    func isPropertySettable(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement) -> Bool

    func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue?,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    func removeListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue?,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
}

extension CoreAudioClient {
    func validDefaultOutputDevice() -> AudioDeviceID? {
        guard
            let deviceID = defaultOutputDevice(),
            deviceID != kAudioObjectUnknown,
            deviceClass(of: deviceID) == kAudioDeviceClassID,
            isDeviceAlive(deviceID)
        else { return nil }

        return deviceID
    }
}

final class CoreAudioSystemClient: CoreAudioClient {
    func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard
            status == noErr,
            size == MemoryLayout<AudioDeviceID>.size,
            deviceID != kAudioObjectUnknown
        else { return nil }
        return deviceID
    }

    func outputChannelElements(deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        CoreAudioOutputChannelElements.channels(for: deviceID)
    }

    func deviceClass(of deviceID: AudioDeviceID) -> AudioClassID? {
        readUInt32(
            objectID: deviceID,
            selector: kAudioObjectPropertyClass,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
    }

    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        ) == 1
    }

    func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        readScalar(
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: element,
            defaultValue: UInt32(0)
        )
    }

    func readFloat32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        readScalar(
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: element,
            defaultValue: Float32(0)
        )
    }

    func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &name
        )

        guard
            status == noErr,
            size == MemoryLayout<Unmanaged<CFString>?>.size,
            let name
        else { return nil }

        let value = name.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    func readURL(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> URL? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var url: Unmanaged<CFURL>?
        var size = UInt32(MemoryLayout<Unmanaged<CFURL>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &url
        )

        guard
            status == noErr,
            size == MemoryLayout<Unmanaged<CFURL>?>.size,
            let url
        else { return nil }

        return url.takeRetainedValue() as URL
    }

    func hasProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        return AudioObjectHasProperty(objectID, &address)
    }

    func isPropertySettable(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(objectID, &address)
            && AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr && settable.boolValue
    }

    func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue?,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var mutableAddress = address
        return AudioObjectAddPropertyListenerBlock(
            objectID,
            &mutableAddress,
            queue,
            block
        )
    }

    func removeListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue?,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var mutableAddress = address
        return AudioObjectRemovePropertyListenerBlock(
            objectID,
            &mutableAddress,
            queue,
            block
        )
    }

    private func readScalar<Value>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        defaultValue: Value
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                UnsafeMutableRawPointer(pointer)
            )
        }

        guard status == noErr, size == MemoryLayout<Value>.size else {
            return nil
        }
        return value
    }
}

final class CoreAudioVolumeReader: VolumeReadingProviding {
    private let client: any CoreAudioClient

    init(client: any CoreAudioClient = CoreAudioSystemClient()) {
        self.client = client
    }

    func read() -> VolumeReading? {
        guard let deviceID = defaultOutputDevice() else { return nil }
        let scalar = volumeScalar(for: deviceID).map(Double.init)
        let canSetVolume = volumeCapability(for: deviceID)
        let canMute = muteCapability(for: deviceID)
        let name = deviceName(for: deviceID)

        return VolumeReading(
            scalar: scalar,
            isMuted: isMuted(for: deviceID),
            deviceName: name,
            currentDevice: AudioOutputDevice(
                id: deviceID,
                name: name,
                uid: deviceUID(for: deviceID),
                isCurrent: true,
                volume: scalar,
                transport: transport(for: deviceID),
                dataSource: dataSource(for: deviceID),
                iconURL: iconURL(for: deviceID),
                modelUID: modelUID(for: deviceID)
            ),
            canSetVolume: canSetVolume,
            canMute: canMute
        )
    }

    func defaultOutputDevice() -> AudioDeviceID? {
        client.validDefaultOutputDevice()
    }

    static func firstValue<Value>(
        from elements: [AudioObjectPropertyElement],
        using read: (AudioObjectPropertyElement) -> Value?
    ) -> Value? {
        for element in elements {
            if let value = read(element) {
                return value
            }
        }
        return nil
    }

    static func isMuted(
        from elements: [AudioObjectPropertyElement],
        using read: (AudioObjectPropertyElement) -> UInt32?
    ) -> Bool {
        firstValue(from: elements, using: read) == 1
    }

    static func fourCharacterCode(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func volumeScalar(for deviceID: AudioDeviceID) -> Float32? {
        let mainVolume = client.readFloat32(
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        )
        if let mainVolume, isValidVolumeScalar(mainVolume), client.isPropertySettable(objectID: deviceID, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementMain) {
            return mainVolume
        }

        let channelVolumes = client.outputChannelElements(deviceID: deviceID).compactMap { element in
            guard client.isPropertySettable(objectID: deviceID, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: element) else { return nil }
            return client.readFloat32(
                objectID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            )
        }.filter(isValidVolumeScalar)

        guard !channelVolumes.isEmpty else { return nil }
        return channelVolumes.reduce(Float32(0), +) / Float32(channelVolumes.count)
    }

    private func volumeCapability(for deviceID: AudioDeviceID) -> Bool {
        let elements = [kAudioObjectPropertyElementMain] + client.outputChannelElements(deviceID: deviceID)
        return elements.contains { client.isPropertySettable(objectID: deviceID, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: $0) }
    }

    private func muteCapability(for deviceID: AudioDeviceID) -> Bool {
        let elements = [kAudioObjectPropertyElementMain] + client.outputChannelElements(deviceID: deviceID)
        return elements.contains { client.isPropertySettable(objectID: deviceID, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: $0) }
    }

    private func isMuted(for deviceID: AudioDeviceID) -> Bool {
        let elements = [kAudioObjectPropertyElementMain]
            + client.outputChannelElements(deviceID: deviceID)
        return Self.isMuted(from: elements) { element in
            client.readUInt32(
                objectID: deviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            )
        }
    }

    private func isValidVolumeScalar(_ value: Float32) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        client.readString(
            objectID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
    }

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        client.readString(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
    }

    /// A Bluetooth device reports its product and vendor IDs here ("200f 4c"),
    /// which is what identifies an AirPods model after a rename.
    private func modelUID(for deviceID: AudioDeviceID) -> String? {
        client.readString(
            objectID: deviceID,
            selector: kAudioDevicePropertyModelUID,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
    }

    private func transport(for deviceID: AudioDeviceID) -> AudioOutputTransport? {
        client.readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        ).map(AudioOutputTransport.init(coreAudioValue:))
    }

    private func dataSource(for deviceID: AudioDeviceID) -> AudioOutputDataSource? {
        client.readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyDataSource,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ).map(AudioOutputDataSource.init(coreAudioValue:))
    }

    private func iconURL(for deviceID: AudioDeviceID) -> URL? {
        client.readURL(
            objectID: deviceID,
            selector: kAudioDevicePropertyIcon,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
    }
}

@MainActor
protocol VolumeEventMonitoring: AnyObject {
    func start(
        onDefaultDeviceChange: @escaping @MainActor @Sendable () -> Void,
        onVolumeChange: @escaping @MainActor @Sendable () -> Void
    )
    func reconcile()
    func recover()
    func stop()
}

@MainActor
final class CoreAudioVolumeEventMonitor: VolumeEventMonitoring {
    private struct DeviceListenerKey: Hashable {
        let selector: AudioObjectPropertySelector
        let element: AudioObjectPropertyElement
    }

    private struct ListenerRegistration {
        let key: DeviceListenerKey
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue?
        let block: AudioObjectPropertyListenerBlock
    }

    nonisolated(unsafe) private let client: any CoreAudioClient
    private let callbackQueue: DispatchQueue?
    nonisolated(unsafe) private var defaultDeviceRegistration: ListenerRegistration?
    nonisolated(unsafe) private var deviceRegistrations: [ListenerRegistration] = []
    private var registeredDeviceID: AudioDeviceID?
    private var deviceNeedsReconciliation = true
    private var onDefaultDeviceChange: (@MainActor @Sendable () -> Void)?
    private var onVolumeChange: (@MainActor @Sendable () -> Void)?
    private var isStarted = false
    private var isStopped = false

    init(
        client: any CoreAudioClient = CoreAudioSystemClient(),
        callbackQueue: DispatchQueue? = .main
    ) {
        self.client = client
        self.callbackQueue = callbackQueue
    }

    deinit {
        if let defaultDeviceRegistration {
            Self.unregister(defaultDeviceRegistration, client: client)
        }
        for registration in deviceRegistrations {
            Self.unregister(registration, client: client)
        }
    }

    func start(
        onDefaultDeviceChange: @escaping @MainActor @Sendable () -> Void,
        onVolumeChange: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !isStarted, !isStopped else { return }
        isStarted = true
        self.onDefaultDeviceChange = onDefaultDeviceChange
        self.onVolumeChange = onVolumeChange
        deviceNeedsReconciliation = true
        reconcile()
    }

    func reconcile() {
        guard isStarted, !isStopped else { return }

        reconcileDefaultDeviceListener()

        let currentDeviceID = client.validDefaultOutputDevice()
        if deviceNeedsReconciliation || currentDeviceID != registeredDeviceID {
            removeDeviceListeners()
            registeredDeviceID = currentDeviceID
            deviceNeedsReconciliation = false
        }

        guard let currentDeviceID else { return }
        reconcileDeviceListeners(for: currentDeviceID)
    }

    func recover() {
        guard isStarted, !isStopped else { return }

        removeAllListeners()
        registeredDeviceID = nil
        deviceNeedsReconciliation = true
        reconcile()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        removeAllListeners()
        registeredDeviceID = nil
        deviceNeedsReconciliation = true
        onDefaultDeviceChange = nil
        onVolumeChange = nil
    }

    private func reconcileDefaultDeviceListener() {
        guard defaultDeviceRegistration == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.defaultDeviceDidChange()
            }
        }
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        defaultDeviceRegistration = addDefaultDeviceListener(
            address: address,
            block: block
        )
    }

    private func reconcileDeviceListeners(for deviceID: AudioDeviceID) {
        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.volumeDidChange()
            }
        }
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.volumeDidChange()
            }
        }

        let elements = [kAudioObjectPropertyElementMain]
            + client.outputChannelElements(deviceID: deviceID)
        let selectors = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]
        let desiredKeys = Set(elements.flatMap { element in
            selectors.compactMap { selector -> DeviceListenerKey? in
                guard client.hasProperty(
                    objectID: deviceID,
                    selector: selector,
                    scope: kAudioObjectPropertyScopeOutput,
                    element: element
                ) else { return nil }
                return DeviceListenerKey(selector: selector, element: element)
            }
        })
        let staleRegistrations = deviceRegistrations.filter {
            $0.objectID == deviceID && !desiredKeys.contains($0.key)
        }
        for registration in staleRegistrations {
            removeListener(registration)
        }
        deviceRegistrations.removeAll { registration in
            staleRegistrations.contains { $0.key == registration.key && $0.objectID == registration.objectID }
        }

        for element in elements {
            reconcileDeviceListener(
                objectID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                element: element,
                block: volumeBlock
            )
            reconcileDeviceListener(
                objectID: deviceID,
                selector: kAudioDevicePropertyMute,
                element: element,
                block: muteBlock
            )
        }
    }

    private func reconcileDeviceListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        let key = DeviceListenerKey(selector: selector, element: element)
        guard !deviceRegistrations.contains(where: { $0.key == key }) else {
            return
        }

        let address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard client.hasProperty(
            objectID: objectID,
            selector: selector,
            scope: kAudioObjectPropertyScopeOutput,
            element: element
        ) else { return }

        guard let registration = addDeviceListener(
            key: key,
            objectID: objectID,
            address: address,
            block: block
        ) else { return }
        deviceRegistrations.append(registration)
    }

    private func defaultDeviceDidChange() {
        guard isStarted, !isStopped else { return }
        deviceNeedsReconciliation = true
        reconcile()
        onDefaultDeviceChange?()
    }

    private func volumeDidChange() {
        guard isStarted, !isStopped else { return }
        onVolumeChange?()
    }

    private func addDefaultDeviceListener(
        address: AudioObjectPropertyAddress,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> ListenerRegistration? {
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        let status = client.addListener(
            objectID: objectID,
            address: address,
            queue: callbackQueue,
            block: block
        )
        if status != noErr {
            volumeMonitorLogger.error(
                "Failed to add CoreAudio default-device listener for selector \(address.mSelector, privacy: .public), element \(address.mElement, privacy: .public): OSStatus \(status, privacy: .public)"
            )
            return nil
        }

        return ListenerRegistration(
            key: DeviceListenerKey(selector: address.mSelector, element: address.mElement),
            objectID: objectID,
            address: address,
            queue: callbackQueue,
            block: block
        )
    }

    private func addDeviceListener(
        key: DeviceListenerKey,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> ListenerRegistration? {
        let status = client.addListener(
            objectID: objectID,
            address: address,
            queue: callbackQueue,
            block: block
        )
        if status != noErr {
            volumeMonitorLogger.error(
                "Failed to add CoreAudio listener for selector \(address.mSelector, privacy: .public), element \(address.mElement, privacy: .public): OSStatus \(status, privacy: .public)"
            )
            return nil
        }

        return ListenerRegistration(
            key: key,
            objectID: objectID,
            address: address,
            queue: callbackQueue,
            block: block
        )
    }

    private func removeAllListeners() {
        if let defaultDeviceRegistration {
            removeListener(defaultDeviceRegistration)
            self.defaultDeviceRegistration = nil
        }
        removeDeviceListeners()
    }

    private func removeDeviceListeners() {
        for registration in deviceRegistrations {
            removeListener(registration)
        }
        deviceRegistrations.removeAll()
    }

    private func removeListener(_ registration: ListenerRegistration) {
        Self.unregister(registration, client: client)
    }

    nonisolated private static func unregister(
        _ registration: ListenerRegistration,
        client: any CoreAudioClient
    ) {
        let status = client.removeListener(
            objectID: registration.objectID,
            address: registration.address,
            queue: registration.queue,
            block: registration.block
        )
        if status != noErr {
            volumeMonitorLogger.error(
                "Failed to remove CoreAudio listener for selector \(registration.address.mSelector, privacy: .public), element \(registration.address.mElement, privacy: .public): OSStatus \(status, privacy: .public)"
            )
        }
    }
}
