// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/UI/StatusBarController.swift
// (the icon render path) and Sources/StatusTrioCore/App/AppEnvironment.swift (the
// charging-effect wiring) (https://github.com/lingyired/status-trio, tag v1.6.0,
// commit 64caf379). Copyright 2026 lingyired. Licensed under the Apache License,
// Version 2.0; see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153):
// draws onto a status button the app owns (its click opens the app's panel, not
// a popover); takes the status and the settings as values; an optional custom
// foreground (the app's menu-bar item colour) replaces the label colour, which
// renders the whole icon as one custom raster.

import AppKit
import Combine

@MainActor
public final class CombinedStatusIconStatusItemPresenter {
    private weak var button: NSStatusBarButton?
    private var renderCache = StatusBarRenderCache()
    private let chargingFrameCache = StatusBarChargingFrameCache()
    private let animationLayerPresenter = StatusBarAnimationLayerPresenter()
    private let renderCoalescer = IconRenderCoalescer()
    private let chargingEffectClock: ChargingEffectClock
    private let motionMonitor: ChargingEffectMotionMonitor
    private let snapshots: CurrentValueSubject<StatusSnapshot, Never>
    private let preferences: CurrentValueSubject<IconPresentationSettings, Never>
    private let iconPresentation: IconPresentationViewModel
    private var latestIconOutput: IconPresentationOutput
    private var currentChargingEffectPhase: ChargingEffectPhase?
    private var settings: CombinedStatusIconSettings
    private var isDisplayAsleep = false
    private var foreground: NSColor?
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var screenParametersObserver: NSObjectProtocol?

    /// The square the icon takes in the menu bar, in points.
    public var iconSize: CGFloat { CGFloat(latestIconOutput.menuBarSize) }
    public var isAttached: Bool { button != nil }

    public init(snapshot: StatusSnapshot, settings: CombinedStatusIconSettings) {
        self.settings = settings
        let presentation = settings.presentationSettings
        snapshots = CurrentValueSubject(snapshot)
        preferences = CurrentValueSubject(presentation)
        chargingEffectClock = ChargingEffectClock()
        motionMonitor = ChargingEffectMotionMonitor()
        iconPresentation = IconPresentationViewModel(
            snapshot: snapshot,
            settings: presentation,
            snapshots: snapshots.eraseToAnyPublisher(),
            preferences: preferences.eraseToAnyPublisher(),
            resolveInputs: { snapshot in
                IconPresentationResourceResolver.inputs(snapshot: snapshot)
            }
        )
        latestIconOutput = iconPresentation.output
    }

    /// Takes over the button's image. The app keeps the item's length equal
    /// to `iconSize`.
    public func attach(to button: NSStatusBarButton) {
        guard self.button !== button else { return }
        detach()
        self.button = button
        button.imagePosition = .imageOnly
        renderCache = StatusBarRenderCache()

        iconPresentation.$output
            .removeDuplicates()
            .sink { [weak self] output in
                guard let self else { return }
                latestIconOutput = output
                renderCoalescer.submit { [weak self] in
                    self?.renderLatestScene()
                }
            }
            .store(in: &cancellables)
        chargingEffectClock.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.renderAnimationPhase(phase)
            }
            .store(in: &cancellables)
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.renderLatestScene()
            }
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderLatestScene()
            }
        }
        motionMonitor.onChange = { [weak self] _ in
            self?.updateChargingEffectClock()
        }
        motionMonitor.start()
        iconPresentation.start()
        updateChargingEffectClock()
        renderLatestScene()
    }

    /// Hands the button back: the overlay layer goes, the clock stops.
    public func detach() {
        cancellables.removeAll()
        appearanceObservation = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        motionMonitor.stop()
        motionMonitor.onChange = nil
        iconPresentation.stop()
        renderCoalescer.cancel()
        chargingEffectClock.stop()
        currentChargingEffectPhase = nil
        chargingFrameCache.reset()
        animationLayerPresenter.clear()
        renderCache.reset()
        button = nil
    }

    /// Only a changed status is sent on: the view model debounces each status
    /// by 500 ms, so repeating an unchanged one would keep postponing it.
    public func update(snapshot: StatusSnapshot, isDisplayAsleep: Bool) {
        let batteryChanged = snapshot.battery != snapshots.value.battery
        let sleepChanged = isDisplayAsleep != self.isDisplayAsleep
        self.isDisplayAsleep = isDisplayAsleep
        if snapshot != snapshots.value { snapshots.send(snapshot) }
        if batteryChanged || sleepChanged { updateChargingEffectClock() }
    }

    public func update(settings: CombinedStatusIconSettings) {
        guard settings != self.settings else { return }
        let effectChanged = settings.showsChargingEffect != self.settings.showsChargingEffect
        self.settings = settings
        preferences.send(settings.presentationSettings)
        if effectChanged { updateChargingEffectClock() }
    }

    /// The app's menu-bar item colour; nil keeps the menu bar's label colour.
    public func update(foreground: NSColor?) {
        guard foreground != self.foreground else { return }
        self.foreground = foreground
        renderCache.reset()
        chargingFrameCache.reset()
        renderLatestScene()
    }

    /// A still icon for a settings preview: the current scene, no effect. A
    /// foreground draws it in the app's menu-bar item colour, as the item does.
    public static func previewImage(
        snapshot: StatusSnapshot,
        settings: CombinedStatusIconSettings,
        size: CGFloat,
        scale: CGFloat,
        appearance: NSAppearance?,
        foreground: NSColor? = nil
    ) -> NSImage? {
        let scene = IconPresentationMapper.scene(
            inputs: IconPresentationResourceResolver.inputs(snapshot: snapshot),
            configuration: settings.configuration
        )
        guard let foreground else {
            return StatusIconRenderer.image(scene: scene, size: size, scale: scale, appearance: appearance)
        }
        let environment = customEnvironment(foreground, size: size, scale: scale,
                                            appearance: appearance ?? NSAppearance.currentDrawing())
        return StatusIconRenderer.render(scene: scene, environment: environment)
            .map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
    }

    private static func customEnvironment(
        _ foreground: NSColor, size: CGFloat, scale: CGFloat, appearance: NSAppearance
    ) -> StatusIconRenderEnvironment {
        var environment = StatusIconRenderEnvironment(size: size, scale: scale,
                                                      foreground: foreground.cgColor,
                                                      criticalColor: StatusIconRenderer.defaultCriticalColor)
        appearance.performAsCurrentDrawingAppearance {
            environment = StatusIconRenderEnvironment(
                size: size, scale: scale,
                foreground: foreground.usingColorSpace(.deviceRGB)?.cgColor ?? foreground.cgColor,
                criticalColor: NSColor.systemRed.usingColorSpace(.deviceRGB)?.cgColor
                    ?? StatusIconRenderer.defaultCriticalColor
            )
        }
        return environment
    }

    private func updateChargingEffectClock() {
        chargingEffectClock.update(
            battery: snapshots.value.battery,
            enabled: settings.showsChargingEffect,
            reduceMotion: motionMonitor.shouldReduceMotion,
            displayAsleep: isDisplayAsleep
        )
    }

    private func render(scene: IconSceneState, iconSize: Double, phase: ChargingEffectPhase?) {
        guard let button else { return }

        let backingScale =
            button.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        let key = StatusBarRenderKey(
            scene: scene,
            iconSize: iconSize,
            backingScale: backingScale,
            appearanceName: button.effectiveAppearance.name.rawValue,
            phase: phase
        )
        guard renderCache.needsRender(key) else { return }

        if let foreground {
            renderCustomForeground(foreground, scene: scene, key: key, iconSize: CGFloat(iconSize),
                                   backingScale: backingScale, phase: phase, button: button)
            return
        }

        guard let layers = StatusIconRenderer.menuBarLayers(
            scene: scene,
            size: CGFloat(iconSize),
            scale: backingScale,
            appearance: button.effectiveAppearance,
            phase: phase
        ) else { return }

        // The button always carries the monochrome template image, so the system
        // keeps re-tinting it for the Space that is on top — including while a
        // Space switch is being dragged (#112).
        button.image = layers.base

        guard let overlay = layers.overlay else {
            clearAnimationPresentation()
            renderCache.recordSuccessfulRender(key)
            return
        }

        if let frame = overlayFrame(
            overlay: overlay,
            scene: scene,
            phase: phase,
            key: key,
            iconSize: CGFloat(iconSize),
            backingScale: backingScale,
            appearance: button.effectiveAppearance
        ) {
            presentOverlayFrame(
                frame,
                button: button,
                iconSize: CGFloat(iconSize),
                backingScale: backingScale
            )
            if phase == nil { chargingFrameCache.reset() }
        } else {
            // The overlay could not be produced; fall back to one custom raster so
            // the status colours still appear, even though they cannot re-tint.
            animationLayerPresenter.clear()
            button.image = StatusIconRenderer.image(
                scene: scene,
                size: CGFloat(iconSize),
                scale: backingScale,
                appearance: button.effectiveAppearance,
                phase: phase
            )
        }
        renderCache.recordSuccessfulRender(key)
    }

    /// The app's item colour is not a label colour the system can re-tint, so
    /// the whole scene is one custom raster above a transparent base, with the
    /// status colours unchanged.
    private func renderCustomForeground(
        _ foreground: NSColor,
        scene: IconSceneState,
        key: StatusBarRenderKey,
        iconSize: CGFloat,
        backingScale: CGFloat,
        phase: ChargingEffectPhase?,
        button: NSStatusBarButton
    ) {
        let environment = Self.customEnvironment(foreground, size: iconSize, scale: backingScale,
                                                 appearance: button.effectiveAppearance)
        guard let base = StatusIconRenderer.transparentMenuBarImage(size: iconSize, scale: backingScale) else { return }
        base.isTemplate = true
        let frame: CGImage?
        if let phase, phase.kind == .steady {
            frame = chargingFrameCache.image(for: phase, key: key, backingScale: backingScale) { framePhase in
                StatusIconRenderer.render(scene: scene, environment: environment, phase: framePhase)
                    .map { NSImage(cgImage: $0, size: NSSize(width: iconSize, height: iconSize)) }
            }?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            frame = StatusIconRenderer.render(scene: scene, environment: environment, phase: phase)
        }
        guard let frame else { return }
        button.image = base
        presentOverlayFrame(frame, button: button, iconSize: iconSize, backingScale: backingScale)
        if phase == nil { chargingFrameCache.reset() }
        renderCache.recordSuccessfulRender(key)
    }

    private func clearAnimationPresentation() {
        chargingFrameCache.reset()
        animationLayerPresenter.clear()
    }

    /// Steady animation frames are pre-rendered once per icon state, so a 20 fps
    /// tick reuses one bitmap; every other phase renders a single overlay frame.
    private func overlayFrame(
        overlay: CGImage,
        scene: IconSceneState,
        phase: ChargingEffectPhase?,
        key: StatusBarRenderKey,
        iconSize: CGFloat,
        backingScale: CGFloat,
        appearance: NSAppearance
    ) -> CGImage? {
        guard let phase, phase.kind == .steady else { return overlay }
        let image = chargingFrameCache.image(
            for: phase,
            key: key,
            backingScale: backingScale,
            renderFrame: { framePhase in
                StatusIconRenderer.preRenderedMenuBarImage(
                    scene: scene,
                    size: iconSize,
                    scale: backingScale,
                    appearance: appearance,
                    phase: framePhase,
                    regions: scene.chromaticRegions
                )
            }
        )
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Draws the chromatic overlay in a layer above the button's template image.
    private func presentOverlayFrame(
        _ image: CGImage,
        button: NSStatusBarButton,
        iconSize: CGFloat,
        backingScale: CGFloat
    ) {
        guard animationLayerPresenter.display(
            image,
            in: button,
            contentSize: CGSize(width: iconSize, height: iconSize),
            backingScale: backingScale
        ) != nil else {
            animationLayerPresenter.clear()
            return
        }
    }

    /// Clock-driven frames bypass the status/setting coalescer; the menu-bar key
    /// includes every phase so the 20-fps stream cannot be deduplicated as static.
    private func renderAnimationPhase(_ phase: ChargingEffectPhase?) {
        currentChargingEffectPhase = phase
        render(
            scene: latestIconOutput.menuBarTestScene ?? latestIconOutput.scene,
            iconSize: latestIconOutput.menuBarSize,
            phase: phase
        )
    }

    /// The status, the appearance, and the window's effective appearance all feed
    /// one cached render, so the newest state wins over a redraw that is still
    /// waiting out the coalescing interval.
    private func renderLatestScene() {
        render(
            scene: latestIconOutput.menuBarTestScene ?? latestIconOutput.scene,
            iconSize: latestIconOutput.menuBarSize,
            phase: currentChargingEffectPhase
        )
    }
}
