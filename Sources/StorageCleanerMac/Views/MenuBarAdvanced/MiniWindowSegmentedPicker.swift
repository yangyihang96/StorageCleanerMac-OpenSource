import AppKit
import SwiftUI

/// SwiftUI's macOS segmented picker can keep its intrinsic width inside a
/// flexible frame. Give the native control the proposed width and distribute
/// its segments equally so every control group shares the same content edges.
struct MiniWindowSegmentedPicker<Selection: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Selection
    let options: [Selection]
    let label: (Selection) -> String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectSegment(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.picker = self
        control.segmentCount = options.count
        for (index, option) in options.enumerated() {
            control.setLabel(label(option), forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        control.selectedSegment = options.firstIndex(of: selection) ?? -1
        control.isEnabled = isEnabled
        control.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        control.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: MiniWindowStyleTokens.controlRowHeight)
    }

    @MainActor
    final class Coordinator: NSObject {
        var picker: MiniWindowSegmentedPicker
        init(_ picker: MiniWindowSegmentedPicker) { self.picker = picker }

        @objc func selectSegment(_ sender: NSSegmentedControl) {
            guard sender.isEnabled,
                  picker.options.indices.contains(sender.selectedSegment) else { return }
            picker.selection = picker.options[sender.selectedSegment]
        }
    }
}
