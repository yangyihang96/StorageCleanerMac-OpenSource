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

    private var controls: some View {
        VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
            Toggle(isOn: Binding(
                get: { MacMiniModePresentation.isOn(fanControl.macMiniModeStatus) },
                set: { enabled in
                    Task { @MainActor in
                        await fanControl.setMacMiniMode(enabled ? .whenOnAC : .off)
                    }
                }
            )) {
                Text(MacMiniModePresentation.title)
                    .font(AdvancedPanelTypography.captionStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(fanControl.isDataOnlyFixture || fanControl.isChangingMacMiniMode
                || fanControl.isPreparingHelper || fanControl.macMiniHelperNeedsUpdate)
            .accessibilityIdentifier("mac-mini-mode-toggle")
            .accessibilityLabel(MacMiniModePresentation.title)
            .accessibilityValue(MacMiniModePresentation.detail(fanControl.macMiniModeStatus))
            .help(MacMiniModePresentation.title + "\n" + MacMiniModePresentation.detail(fanControl.macMiniModeStatus))

            if MacMiniModePresentation.isOn(fanControl.macMiniModeStatus) {
                Text(MacMiniModePresentation.safetyNotice)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = fanControl.macMiniModeMessage
                ?? MacMiniModePresentation.reason(fanControl.macMiniModeStatus) {
                Text(message)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mac-mini-mode-reason")
            }
            if fanControl.macMiniHelperNeedsUpdate {
                Button(L10n.text("更新并重新授权系统助手", "Update and Authorize System Helper")) {
                    Task { @MainActor in await fanControl.updateMacMiniModeHelper() }
                }
                .buttonStyle(ResponsivePlainButtonStyle())
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
