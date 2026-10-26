import SwiftUI

/// Developer Junk's landing extras on the gradient: the activity threshold
/// that sorts developer caches into green, yellow and red (D22), and the two
/// separate tools (project artifacts, iOS simulators).
struct CareStudioDeveloperThresholdControl: View {
    @ObservedObject var store: ScanStore

    private var threshold: Binding<Int> {
        Binding(get: { store.developerInactivityThresholdDays },
                set: { store.setDeveloperInactivityThresholdDays($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("开发文件活动阈值", "Developer Activity Threshold"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(L10n.text("超过一年为绿色，超过阈值为黄色，阈值以内为红色。",
                                   "Over a year is green, older than this is yellow, within it is red."))
                        .font(.system(size: 11))
                        .foregroundStyle(CareStudioInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Stepper(value: threshold,
                        in: DeveloperCleanupAgePolicy.minimumThresholdDays...DeveloperCleanupAgePolicy.maximumThresholdDays) {
                    Text(L10n.text("\(store.developerInactivityThresholdDays) 天", "\(store.developerInactivityThresholdDays) days"))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
                .fixedSize()
                .disabled(store.isPreparingScan)
            }
            HStack(spacing: 8) {
                ProjectArtifactEntryButton(coordinator: store.heavyWorkCoordinator)
                SimulatorCleanupEntryButton(coordinator: store.heavyWorkCoordinator)
            }
            .buttonStyle(CareStudioCapsuleButtonStyle())
        }
        .foregroundStyle(CareStudioInk.primary)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CareStudioInk.panelFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CareStudioInk.hairline, lineWidth: 1))
#if DEBUG
        .layoutProbe("careStudio.developer.threshold")
#endif
    }
}

/// A translucent capsule for buttons that live in other views (the project
/// and simulator entry buttons own their sheets).
struct CareStudioCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CareStudioInk.primary)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule(style: .continuous)
                .fill(configuration.isPressed ? CareStudioInk.pillFillPressed : CareStudioInk.pillFill))
            .overlay(Capsule(style: .continuous).strokeBorder(CareStudioInk.hairline, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}
