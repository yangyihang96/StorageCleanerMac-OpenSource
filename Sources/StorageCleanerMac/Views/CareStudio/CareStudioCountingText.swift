import SwiftUI

/// D154 batch 3P: CleanMyMac's big numbers count up from 0 when they appear —
/// the completion page's amount, the result cards, My Activity. The page that
/// shows them sets `counted` once, where a relayout does not rebuild it (so a
/// resized window does not count again), and the change plays on the shared
/// counter curve (`AppMotion.data`). The text keeps its final size and the
/// count is drawn over it, so nothing around it moves; Reduce Motion and still
/// captures show the result at once, and VoiceOver reads only the result.
struct CareStudioCountingText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let text: String
    let counted: Bool
    var alignment: Alignment = .leading
    var delay: Double = 0

    init(_ text: String, counted: Bool, alignment: Alignment = .leading, delay: Double = 0) {
        self.text = text
        self.counted = counted
        self.alignment = alignment
        self.delay = delay
    }

    var body: some View {
        let still = reduceMotion || disablesAnimations
        Text(text)
            .opacity(0)
            .modifier(CareStudioCountingOverlay(text: text, alignment: alignment,
                                               progress: counted || still ? 1 : 0))
            .animation(still ? nil : AppMotion.data.delay(delay), value: counted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

/// Draws `text` with its numbers at `progress` of their value over the text
/// at its final size; SwiftUI animates `progress` (as the D70 pages'
/// `ByteCountText`, which counts bytes only and lets its width change).
struct CareStudioCountingOverlay: ViewModifier, @preconcurrency Animatable {
    let text: String
    let alignment: Alignment
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            Text(CareStudioCount.text(text, progress: progress))
        }
    }
}

/// The text of a number part of the way through its count: every number in
/// it at `progress` of itself, rounded down, and written as the text writes
/// it — its decimals and its grouping and decimal marks ("2.16 GB",
/// "1,234", "1.234,5 MB"). At 1 it is the text itself.
enum CareStudioCount {
    static func hasNumber(_ text: String) -> Bool {
        text.contains(where: isDigit)
    }

    static func text(_ text: String, progress: Double) -> String {
        guard progress < 1, hasNumber(text) else { return text }
        let fraction = max(0, progress)
        var result = ""
        var rest = Substring(text)
        while let start = rest.firstIndex(where: isDigit) {
            result += rest[..<start]
            var end = rest.index(after: start)
            var index = end
            // Digits, and single marks between digits.
            while index < rest.endIndex {
                let character = rest[index]
                if isDigit(character) {
                    index = rest.index(after: index)
                    end = index
                } else if character == "." || character == ",",
                          rest.index(after: index) < rest.endIndex, isDigit(rest[rest.index(after: index)]) {
                    index = rest.index(after: index)
                } else {
                    break
                }
            }
            result += WrittenNumber(String(rest[start..<end])).written(at: fraction)
            rest = rest[end...]
        }
        return result + rest
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private struct WrittenNumber {
        /// The value in units of its last decimal place.
        let units: Int64
        let decimals: Int
        let decimalMark: Character?
        let groupingMark: Character?

        init(_ token: String) {
            let marks = token.filter { $0 == "." || $0 == "," }
            var decimalMark: Character?
            var groupingMark: Character?
            if let last = marks.last {
                if Set(marks).count == 2 {
                    decimalMark = last
                    groupingMark = marks.first { $0 != last }
                } else if marks.count > 1 {
                    groupingMark = last
                } else {
                    // "1,234" groups thousands; "2.3" and "0.125" have decimals.
                    let parts = token.split(separator: last, omittingEmptySubsequences: false)
                    if parts[1].count == 3, parts[0] != "0" { groupingMark = last } else { decimalMark = last }
                }
            }
            let fractionDigits = decimalMark.flatMap { mark in token.split(separator: mark).last }.map(\.count) ?? 0
            self.units = Int64(token.filter(\.isNumber)) ?? 0
            self.decimals = fractionDigits
            self.decimalMark = decimalMark
            self.groupingMark = groupingMark
        }

        func written(at fraction: Double) -> String {
            let current = Int64((Double(units) * fraction).rounded(.down))
            var scale: Int64 = 1
            for _ in 0..<decimals { scale *= 10 }
            var whole = String(current / scale)
            if let groupingMark {
                var grouped = ""
                for (offset, digit) in whole.reversed().enumerated() {
                    if offset > 0, offset % 3 == 0 { grouped.append(groupingMark) }
                    grouped.append(digit)
                }
                whole = String(grouped.reversed())
            }
            guard decimals > 0, let decimalMark else { return whole }
            let tail = String(current % scale)
            return whole + String(decimalMark) + String(repeating: "0", count: decimals - tail.count) + tail
        }
    }
}
