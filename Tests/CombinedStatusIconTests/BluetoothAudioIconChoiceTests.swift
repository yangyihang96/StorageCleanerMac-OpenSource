// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/BluetoothAudioIconChoiceTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon; dropped what tests the Dock icon, the settings preview, the localization tables or the settings store, which this app does not include.

import AppKit
import Testing
import XCTest
@testable import CombinedStatusIcon

@MainActor
struct BluetoothAudioIconChoiceTests {
    @Test func catalogOffersDistinctAudioShapesAndKnownProductGlyphs() {
        let symbols = BluetoothAudioIconChoice.allCases.compactMap(\.symbolName)

        #expect(symbols.contains("earbuds"))
        #expect(symbols.contains("earbuds.case") == false)
        #expect(symbols.contains("headphones.over.ear"))
        #expect(symbols.contains("headset"))
        #expect(symbols.contains("earpods"))
        #expect(symbols.contains("airpods.pro.gen3"))
        #expect(symbols.contains("beats.powerbeats.pro.2"))
        #expect(symbols.contains("homepod.mini"))
        #expect(symbols.contains("hifispeaker.2"))
        #expect(symbols.contains("speaker.wave.2"))
        #expect(symbols.contains("radio") == false)
        #expect(BluetoothAudioIconChoice.allCases.count == 31)
        #expect(symbols.count == 30)
        #expect(symbols.contains("airpods.gen5") == false)
        #expect(symbols.contains("speaker.bluetooth") == false)
    }

    @Test func availableCatalogAlwaysIncludesAutomaticAndFiltersUnsupportedSymbols() {
        let choices = BluetoothAudioIconChoice.availableChoices { $0 != "airpods.pro.gen3" }

        #expect(choices.first == .automatic)
        #expect(choices.contains(.airpodsProGen3) == false)
        #expect(choices.contains(.airpodsGen4))
        #expect(choices.contains { $0.rawValue == "earbuds.case" } == false)
        #expect(choices.contains { $0.rawValue == "radio" } == false)
    }

    @Test func VenturaAvailabilityFiltersEveryCustomChoiceAndPreservesAutomatic() throws {
        let tableURL = URL(
            fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle"
                + "/Contents/Resources/name_availability.plist"
        )
        guard let data = try? Data(contentsOf: tableURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let symbols = plist["symbols"] as? [String: String],
              let releases = plist["year_to_release"] as? [String: [String: String]]
        else {
            throw XCTSkip("CoreGlyphs availability table is not present on this host")
        }

        func shippedByVentura(_ symbol: String) -> Bool {
            guard let year = symbols[symbol],
                  let version = releases[year]?["macOS"]
            else { return false }
            let parts = version.split(separator: ".").compactMap { Int($0) }
            guard let major = parts.first else { return false }
            let minor = parts.dropFirst().first ?? 0
            let patch = parts.dropFirst(2).first ?? 0
            return major < 13 || (major == 13 && minor == 0 && patch == 0)
        }

        let customChoices = BluetoothAudioIconChoice.allCases.filter { $0 != .automatic }
        let available = BluetoothAudioIconChoice.availableChoices(isSymbolAvailable: shippedByVentura)
        let expectedAvailable = customChoices.filter { choice in
            guard let symbol = choice.symbolName else { return false }
            return shippedByVentura(symbol)
        }
        #expect(customChoices.count == 30)
        #expect(Set(available) == Set([.automatic] + expectedAvailable))

        for choice in customChoices {
            guard let symbol = choice.symbolName else { continue }
            let savedRawValue = choice.rawValue
            let restored = BluetoothAudioIconChoice.persisted(
                savedRawValue,
                isSymbolAvailable: shippedByVentura
            )
            if shippedByVentura(symbol) {
                #expect(restored == choice)
            } else {
                #expect(restored == .automatic)
                #expect(available.contains(choice) == false)
            }
        }

        let automaticRawValue = BluetoothAudioIconChoice.automatic.rawValue
        #expect(BluetoothAudioIconChoice.persisted(
            automaticRawValue,
            isSymbolAvailable: shippedByVentura
        ) == .automatic)
        #expect(automaticRawValue == "automatic")

        let device = AudioOutputDevice(id: 8, name: "Bluetooth Headphones", isCurrent: true, transport: .bluetooth)
        #expect(AudioOutputDeviceIcon.kind(for: device) == .headphones)
        let snapshot = StatusSnapshot(
            battery: .placeholder,
            wifi: WiFiStatus(state: .connected, rssi: -50),
            connection: .wifi,
            volume: VolumeStatus(scalar: 0.5, isMuted: false, deviceName: "Bluetooth Headphones", currentDevice: device)
        )
        let inputs = IconPresentationResourceResolver.inputs(
            snapshot: snapshot,
            isSymbolAvailable: shippedByVentura
        )
        #expect(inputs.audioIcon == .symbol(name: "headphones", variableValue: nil, fallback: "headphones"))
    }

    @Test func unsupportedSavedChoiceFallsBackToAutomatic() {
        #expect(BluetoothAudioIconChoice.persisted("airpods.pro.gen3", isSymbolAvailable: { _ in false }) == .automatic)
        #expect(BluetoothAudioIconChoice.persisted("not-a-real-symbol", isSymbolAvailable: { _ in true }) == .automatic)
        #expect(BluetoothAudioIconChoice.persisted("airpods.pro.gen3", isSymbolAvailable: { _ in true }) == .airpodsProGen3)
        #expect(BluetoothAudioIconChoice.persisted("earbuds.case", isSymbolAvailable: { _ in true }) == .automatic)
        #expect(BluetoothAudioIconChoice.persisted("radio", isSymbolAvailable: { _ in true }) == .automatic)
    }

    @Test func globalChoiceAppliesOnlyToBluetoothAndLEAudio() {
        let options = BluetoothAudioIconOptions(
            replacesNetworkIcon: true,
            prioritizesNetworkErrors: false,
            iconChoice: .airpodsPro
        )
        let bluetoothScene = scene(transport: .bluetooth, options: options)
        let lowEnergyScene = scene(transport: .bluetoothLowEnergy, options: options)
        let wiredScene = scene(transport: .usb, options: options)
        let expected = CenterState.symbol(IconSymbolState(
            source: .symbol(name: "airpods.pro", variableValue: nil, fallback: "headphones"),
            color: .bluetooth,
            scale: BluetoothAudioIconOptions.defaultSymbolScale
        ))

        #expect(bluetoothScene.center == expected)
        #expect(lowEnergyScene.center == expected)
        #expect(wiredScene.center != expected)
    }

    @Test func unsupportedChoiceFallsBackToAutomaticAndPickedNetworkDeviceWins() {
        let unsupported = BluetoothAudioIconOptions(
            replacesNetworkIcon: true,
            prioritizesNetworkErrors: false,
            iconChoice: BluetoothAudioIconChoice.persisted("airpods.pro.gen3", isSymbolAvailable: { _ in false })
        )
        let automaticScene = scene(transport: .bluetooth, options: unsupported)
        #expect(automaticScene.center == CenterState.symbol(IconSymbolState(
            source: .symbol(name: "headphones", variableValue: nil, fallback: nil),
            color: .bluetooth,
            scale: BluetoothAudioIconOptions.defaultSymbolScale
        )))

        let pickedDevice = BluetoothAudioIconOptions(
            replacesNetworkIcon: true,
            prioritizesNetworkErrors: false,
            networkIconSymbolOverride: "picked.device",
            iconChoice: .airpodsPro
        )
        let pickedScene = scene(transport: .usb, options: pickedDevice)
        #expect(pickedScene.center == CenterState.symbol(IconSymbolState(
            source: .symbol(name: "picked.device", variableValue: nil, fallback: "dot.radiowaves.left.and.right"),
            color: .bluetooth,
            scale: BluetoothAudioIconOptions.defaultSymbolScale
        )))
    }

    @Test func everyVisibleChoiceResolvesToAnInstalledSystemSymbol() {
        let choices = BluetoothAudioIconChoice.availableChoices {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }

        #expect(choices.first == .automatic)
        #expect(choices.count > 20)
        #expect(choices.dropFirst().allSatisfy { choice in
            guard let symbol = choice.symbolName else { return false }
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        })
    }

    private func scene(
        transport: AudioOutputTransport,
        options: BluetoothAudioIconOptions
    ) -> IconSceneState {
        let device = AudioOutputDevice(id: 7, name: "Test Audio", isCurrent: true, transport: transport)
        let snapshot = StatusSnapshot(
            battery: .placeholder,
            wifi: WiFiStatus(state: .connected, rssi: -48),
            connection: .wifi,
            volume: VolumeStatus(scalar: 0.5, isMuted: false, deviceName: "Test Audio", currentDevice: device)
        )
        let inputs = IconPresentationInputs(
            snapshot: snapshot,
            audioIcon: .symbol(name: "headphones", variableValue: nil, fallback: nil)
        )
        let configuration = IconPresentationConfiguration(
            battery: .standard,
            connection: .standard,
            volume: .standard,
            bluetooth: options
        )
        return IconPresentationMapper.scene(inputs: inputs, configuration: configuration)
    }
}
