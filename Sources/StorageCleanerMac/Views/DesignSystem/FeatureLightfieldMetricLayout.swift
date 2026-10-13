import SwiftUI

/// Measures the uncompressed native Text views. Compact statistics grow into
/// balanced rows instead of shrinking or clipping either the label or value.
struct LightfieldInlineMetricsLayout: Layout {
    private let rowGap: CGFloat = 12

    private func arrangement(width: CGFloat, subviews: Subviews) -> (columns: Int, gap: CGFloat, columnWidth: CGFloat) {
        let count = max(1, subviews.count)
        let minimum = subviews.map { ceil($0.sizeThatFits(.unspecified).width) }.max() ?? 0
        // Six counts use 6, 3, 2 or 1 columns: no isolated orphan count.
        for columns in stride(from: count, through: 1, by: -1) where count.isMultiple(of: columns) {
            let gap = min(16, width / CGFloat(columns) * 0.2)
            let columnWidth = max(0, (width - gap * CGFloat(columns - 1)) / CGFloat(columns))
            if columnWidth >= minimum || columns == 1 { return (columns, gap, columnWidth) }
        }
        return (1, 0, width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width } + CGFloat(subviews.count - 1) * 16
        let grid = arrangement(width: width, subviews: subviews)
        let cellProposal = ProposedViewSize(width: grid.columnWidth, height: nil)
        let height = subviews.map { $0.sizeThatFits(cellProposal).height }.max() ?? 48
        let rows = (subviews.count + grid.columns - 1) / grid.columns
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(rows - 1) * rowGap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = arrangement(width: bounds.width, subviews: subviews)
        let cellProposal = ProposedViewSize(width: grid.columnWidth, height: nil)
        let height = subviews.map { $0.sizeThatFits(cellProposal).height }.max() ?? 48
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(
                x: bounds.minX + CGFloat(index % grid.columns) * (grid.columnWidth + grid.gap),
                y: bounds.minY + CGFloat(index / grid.columns) * (height + rowGap)),
                anchor: .topLeading, proposal: ProposedViewSize(width: grid.columnWidth, height: height))
        }
    }
}

/// Full-width cells retain number + label; compact cells put the complete
/// label below the complete number. The parent uses this minimum native width.
struct LightfieldInlineMetricLayout: Layout {
    private let gap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let minimum = sizes.map(\.width).max() ?? 0
        let width = proposal.width ?? ceil(minimum)
        let horizontal = sizes.reduce(CGFloat(0)) { $0 + $1.width } + gap
        let height = width >= horizontal
            ? (sizes.map(\.height).max() ?? 0) : sizes.reduce(CGFloat(0)) { $0 + $1.height }
        return CGSize(width: width, height: max(48, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let horizontal = sizes.reduce(CGFloat(0)) { $0 + $1.width } + gap
        if bounds.width >= horizontal {
            var x = bounds.minX
            // Match the approved first-baseline horizontal count row.
            let baselines = subviews.map { $0.dimensions(in: .unspecified)[.firstTextBaseline] }
            let baseline = baselines.max() ?? 0
            let top = bounds.midY - (sizes.map(\.height).max() ?? 0) / 2
            for index in subviews.indices {
                subviews[index].place(at: CGPoint(x: x, y: top + baseline - baselines[index]),
                    anchor: .topLeading, proposal: .unspecified)
                x += sizes[index].width + gap
            }
        } else {
            var y = bounds.midY - sizes.reduce(CGFloat(0)) { $0 + $1.height } / 2
            for index in subviews.indices {
                subviews[index].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: .unspecified)
                y += sizes[index].height
            }
        }
    }
}
