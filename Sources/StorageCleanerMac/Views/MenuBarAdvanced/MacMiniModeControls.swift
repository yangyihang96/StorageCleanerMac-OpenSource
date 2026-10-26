import FanControlShared
import SwiftUI

struct MacMiniModeControls: View {
    @ObservedObject var fanControl: FanControlCoordinator
    let hasInternalBattery: Bool

    var body: some View {
        if MacMiniHardwareCapabilities.shouldOffer(hasInternalBattery: hasInternalBattery, isDataOnlyFixture: fanControl.isDataOnlyFixture) {
            controls
        }
    }

    /// D124: a text section of the energy-mode page: the major label with
    /// iStat's text-section toggle on the right, the policy and its notes
    /// below, the helper update as an action row (was a native switch with
    /// the full title beside it).
    private var controls: some View {
        GeekIStatTextSectionCard {
            GeekIStatMajorLabelRow(title: MacMiniModePresentation.sectionTitle) {
                Toggle(isOn: Binding(
                    get: { MacMiniModePresentation.isOn(fanControl.macMiniModeStatus) },
                    set: { enabled in
                        Task { @MainActor in
                            await fanControl.setMacMiniMode(enabled ? .whenOnAC : .off)
                        }
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(GeekIStatSwitchToggleStyle())
                .disabled(fanControl.isDataOnlyFixture || fanControl.isChangingMacMiniMode
                    || fanControl.isPreparingHelper || fanControl.macMiniHelperNeedsUpdate)
                .accessibilityIdentifier("mac-mini-mode-toggle")
                .accessibilityLabel(MacMiniModePresentation.title)
                .accessibilityHint(MacMiniModePresentation.detail(fanControl.macMiniModeStatus))
                .help(MacMiniModePresentation.title + "\n" + MacMiniModePresentation.detail(fanControl.macMiniModeStatus))
            }

            Text(MacMiniModePresentation.summary)
                .geekIStatSectionNote()
            if MacMiniModePresentation.isOn(fanControl.macMiniModeStatus) {
                Text(MacMiniModePresentation.safetyNotice)
                    .geekIStatSectionNote()
            }
            if let message = fanControl.macMiniModeMessage
                ?? MacMiniModePresentation.reason(fanControl.macMiniModeStatus) {
                Text(message)
                    .geekIStatSectionNote(AppDesignTokens.Palette.warning)
                    .accessibilityIdentifier("mac-mini-mode-reason")
            }
            if fanControl.macMiniHelperNeedsUpdate {
                GeekIStatTickRow(
                    title: L10n.text("更新并重新授权系统助手", "Update and Authorize System Helper"),
                    isSelected: false,
                    showsCheck: false
                ) {
                    Task { @MainActor in await fanControl.updateMacMiniModeHelper() }
                }
                .disabled(fanControl.isDataOnlyFixture || fanControl.isChangingMacMiniMode || fanControl.isPreparingHelper)
            }
        }
        .task(id: MacMiniModePresentation.isOn(fanControl.macMiniModeStatus)) {
            guard !fanControl.isDataOnlyFixture else { return }
            await fanControl.refreshMacMiniMode()
            // Poll only while this visible control shows an enabled policy.
            // Off has no background preference timer; an open XPC demand handle
            // continues to keep the helper alive until the client disconnects.
            while !Task.isCancelled, MacMiniModePresentation.isOn(fanControl.macMiniModeStatus) {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled else { return }
                await fanControl.refreshMacMiniMode()
            }
        }
    }
}
