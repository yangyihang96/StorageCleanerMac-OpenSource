import Foundation

// Squarified layout adapted from disktree/core/treemap.rs.
// Copyright (c) 2026 Tobi Lütke
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

enum SpaceMapTreemapLayout {
    struct Options: Equatable, Sendable {
        let maxDepth: Int
        let padding: CGFloat
        let outerPadding: CGFloat
        let minimumTileSide: CGFloat
        let maximumChildren: Int
        let headerHeight: CGFloat
        let innerHeaderHeight: CGFloat
        let minimumHeaderWidth: CGFloat

        init(
            maxDepth: Int = 3,
            padding: CGFloat = 1,
            outerPadding: CGFloat = 3,
            minimumTileSide: CGFloat = 5,
            maximumChildren: Int = 96,
            headerHeight: CGFloat = 20,
            innerHeaderHeight: CGFloat = 15,
            minimumHeaderWidth: CGFloat = 44
        ) {
            self.maxDepth = min(6, max(1, maxDepth))
            self.padding = max(0, padding)
            self.outerPadding = max(0, outerPadding)
            self.minimumTileSide = max(0, minimumTileSide)
            self.maximumChildren = max(0, maximumChildren)
            self.headerHeight = max(0, headerHeight)
            self.innerHeaderHeight = max(0, innerHeaderHeight)
            self.minimumHeaderWidth = max(0, minimumHeaderWidth)
        }
    }

    struct Tile: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case entry(StorageTreemapEntry)
            case others(parentPath: String, count: Int, bytes: Int64)
        }

        let kind: Kind
        let frame: CGRect
        let depth: Int
        let header: CGRect?
    }

    /// Bruls–Huizing–van Wijk squarification, returned in the original order.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var frames = Array(repeating: CGRect.zero, count: values.count)
        guard hasArea(rect), (rect.width * rect.height).isFinite else { return frames }
        let order = values.indices.filter { values[$0].isFinite && values[$0] > 0 }.sorted {
            values[$0] == values[$1] ? $0 < $1 : values[$0] > values[$1]
        }
        guard let largestIndex = order.first else { return frames }
        // Normalize before summing: even several finite Double.max values
        // must not overflow the total and collapse every rectangle to zero.
        let largest = values[largestIndex]
        let total = order.reduce(0.0) { $0 + values[$1] / largest }
        let area = Double(rect.width * rect.height)
        let areas = order.map { (values[$0] / largest) / total * area }
        var free = rect
        var start = 0
        while start < areas.count && hasArea(free) {
            guard areas[start] > 0 else { break }
            let side = Double(min(free.width, free.height))
            var end = start + 1
            var sum = areas[start]
            let biggest = areas[start]
            var worst = worstRatio(sum: sum, smallest: areas[start], biggest: biggest, side: side)
            while end < areas.count && areas[end] > 0 {
                let candidateSum = sum + areas[end]
                let candidateWorst = worstRatio(
                    sum: candidateSum, smallest: areas[end], biggest: biggest, side: side
                )
                if candidateWorst > worst { break }
                sum = candidateSum
                worst = candidateWorst
                end += 1
            }

            if free.width >= free.height {
                let width = end == areas.count
                    ? free.width : min(free.width, CGFloat(sum / Double(free.height)))
                var y = free.minY
                for slot in start..<end {
                    let height = slot == end - 1
                        ? max(0, free.maxY - y)
                        : min(max(0, free.maxY - y), CGFloat(areas[slot] / Double(width)))
                    frames[order[slot]] = CGRect(x: free.minX, y: y, width: width, height: height)
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY,
                              width: max(0, free.width - width), height: free.height)
            } else {
                let height = end == areas.count
                    ? free.height : min(free.height, CGFloat(sum / Double(free.width)))
                var x = free.minX
                for slot in start..<end {
                    let width = slot == end - 1
                        ? max(0, free.maxX - x)
                        : min(max(0, free.maxX - x), CGFloat(areas[slot] / Double(height)))
                    frames[order[slot]] = CGRect(x: x, y: free.minY, width: width, height: height)
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height,
                              width: free.width, height: max(0, free.height - height))
            }
            start = end
        }
        return frames
    }

    static func layout(
        rootPath: String,
        rootEntries: [StorageTreemapEntry],
        in rect: CGRect,
        options: Options,
        children: (String) -> [StorageTreemapEntry],
        filter: SpaceMapTreemapFilter.Result? = nil
    ) -> [Tile] {
        var tiles: [Tile] = []
        let parentPath = DiskScanner.storageMapLogicalPath(rootPath)
        place(rootEntries, parentPath: parentPath, in: rect, depth: 0, options: options,
              children: children, filter: filter, output: &tiles)
        return tiles
    }

    static func hitTest(_ tiles: [Tile], at point: CGPoint) -> Tile? {
        tiles.reversed().first { $0.frame.contains(point) }
    }

    private struct RankedEntry: Sendable {
        let entry: StorageTreemapEntry
        let bytes: Int64
        let position: Int
    }

    private static func place(
        _ entries: [StorageTreemapEntry],
        parentPath: String,
        in rect: CGRect,
        depth: Int,
        options: Options,
        children: (String) -> [StorageTreemapEntry],
        filter: SpaceMapTreemapFilter.Result?,
        output: inout [Tile]
    ) {
        guard hasArea(rect) else { return }
        let ranked = entries.enumerated().compactMap { position, entry -> RankedEntry? in
            let bytes: Int64
            if let filter {
                guard let keep = filter.keep(forPath: entry.path) else { return nil }
                switch keep {
                case .whole: bytes = entry.sizeBytes
                case let .partial(matchedBytes, _): bytes = matchedBytes
                }
            } else {
                bytes = entry.sizeBytes
            }
            return bytes > 0 ? RankedEntry(entry: entry, bytes: bytes, position: position) : nil
        }.sorted {
            $0.bytes == $1.bytes ? $0.position < $1.position : $0.bytes > $1.bytes
        }
        let kept = min(ranked.count, options.maximumChildren)
        let tail = ranked.dropFirst(kept)
        let tailBytes = tail.reduce(Int64(0)) { saturatingAdd($0, $1.bytes) }
        var values = ranked.prefix(kept).map { Double($0.bytes) }
        if !tail.isEmpty { values.append(Double(tailBytes)) }
        let frames = squarify(values, in: rect)
        let padding = depth == 0 ? options.outerPadding : options.padding
        for (slot, raw) in frames.enumerated() {
            guard raw.width > padding * 2, raw.height > padding * 2 else { continue }
            let frame = raw.insetBy(dx: padding, dy: padding)
            guard frame.width >= options.minimumTileSide,
                  frame.height >= options.minimumTileSide else { continue }
            guard slot < kept else {
                output.append(Tile(kind: .others(parentPath: parentPath, count: tail.count, bytes: tailBytes),
                                   frame: frame, depth: depth, header: nil))
                continue
            }
            let entry = ranked[slot].entry
            let parentIndex = output.count
            output.append(Tile(kind: .entry(entry), frame: frame, depth: depth, header: nil))
            guard entry.role == .content, entry.isDirectory, entry.canDescend,
                  !entry.isCloudOnly, entry.kind != "package", depth + 1 < options.maxDepth,
                  let header = headerBand(in: frame, depth: depth, options: options) else { continue }
            let body = CGRect(x: frame.minX, y: header.maxY, width: frame.width,
                              height: max(0, frame.maxY - header.maxY))
            let childStart = output.count
            let innerFilter = filter?.keep(forPath: entry.path) == .whole ? nil : filter
            place(children(entry.path), parentPath: entry.path, in: body, depth: depth + 1,
                  options: options, children: children, filter: innerFilter, output: &output)
            // Empty or entirely invisible children leave a closed directory.
            if output.count > childStart {
                output[parentIndex] = Tile(kind: .entry(entry), frame: frame, depth: depth, header: header)
            }
        }
    }

    private static func headerBand(in frame: CGRect, depth: Int, options: Options) -> CGRect? {
        let height = depth == 0 ? options.headerHeight : options.innerHeaderHeight
        guard height > 0, frame.width >= options.minimumHeaderWidth,
              frame.height - height >= options.minimumTileSide * 3 else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
    }

    private static func hasArea(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func worstRatio(sum: Double, smallest: Double, biggest: Double, side: Double) -> Double {
        guard sum > 0, smallest > 0, side > 0 else { return .infinity }
        let thickness = sum / side
        return max(thickness / (smallest / thickness), (biggest / thickness) / thickness)
    }
}
