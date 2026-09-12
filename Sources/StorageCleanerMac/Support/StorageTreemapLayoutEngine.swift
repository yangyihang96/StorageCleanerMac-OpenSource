import CoreGraphics

enum StorageMapWorkspaceLayout {
    static let splitBreakpoint: CGFloat = 720
    static let minimumEntryListWidth: CGFloat = 280
    static let maximumEntryListWidth: CGFloat = 420
    static let preferredEntryListShare: CGFloat = 0.34
    static let columnWidth: CGFloat = 304

    static func showsEntryList(availableWidth: CGFloat) -> Bool {
        availableWidth.isFinite && availableWidth >= splitBreakpoint
    }

    static func entryListWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else {
            return minimumEntryListWidth
        }
        return min(
            maximumEntryListWidth,
            max(minimumEntryListWidth, availableWidth * preferredEntryListShare)
        )
    }
}

enum StorageTreemapLayoutEngine {
    static func frames(
        weights: [Double],
        in bounds: CGRect,
        spacing: CGFloat = 4
    ) -> [CGRect] {
        guard bounds.width > 0, bounds.height > 0, !weights.isEmpty else {
            return Array(repeating: .zero, count: weights.count)
        }

        let weightedItems = weights.enumerated().compactMap { index, weight -> WeightedItem? in
            guard weight.isFinite, weight > 0 else { return nil }
            return WeightedItem(index: index, weight: weight)
        }
        guard !weightedItems.isEmpty else {
            return Array(repeating: .zero, count: weights.count)
        }

        var result = Array(repeating: CGRect.zero, count: weights.count)
        layout(weightedItems, in: bounds, spacing: max(0, spacing), result: &result)
        return result
    }

    private struct WeightedItem {
        let index: Int
        let weight: Double
    }

    private static func layout(
        _ items: [WeightedItem],
        in rect: CGRect,
        spacing: CGFloat,
        result: inout [CGRect]
    ) {
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return }
        if items.count == 1 {
            let inset = min(spacing / 2, min(rect.width, rect.height) / 4)
            result[items[0].index] = rect.insetBy(dx: inset, dy: inset)
            return
        }

        let total = items.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return }

        var firstWeight = 0.0
        var splitIndex = 1
        var bestDifference = Double.greatestFiniteMagnitude
        for index in 1..<items.count {
            firstWeight += items[index - 1].weight
            let difference = abs(total - (firstWeight * 2))
            if difference < bestDifference {
                bestDifference = difference
                splitIndex = index
            }
        }

        let firstItems = Array(items[..<splitIndex])
        let secondItems = Array(items[splitIndex...])
        let firstTotal = firstItems.reduce(0) { $0 + $1.weight }
        let ratio = CGFloat(firstTotal / total)

        if rect.width >= rect.height {
            let firstWidth = rect.width * ratio
            layout(
                firstItems,
                in: CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                spacing: spacing,
                result: &result
            )
            layout(
                secondItems,
                in: CGRect(x: rect.minX + firstWidth, y: rect.minY, width: rect.width - firstWidth, height: rect.height),
                spacing: spacing,
                result: &result
            )
        } else {
            let firstHeight = rect.height * ratio
            layout(
                firstItems,
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                spacing: spacing,
                result: &result
            )
            layout(
                secondItems,
                in: CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: rect.height - firstHeight),
                spacing: spacing,
                result: &result
            )
        }
    }
}
