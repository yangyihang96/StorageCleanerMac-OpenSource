import Foundation

/// The App, replacement/recovery verifier and privileged helper use the same
/// strict marketing/build ordering, including build-only Sparkle releases.
public enum ApplicationUpdateVersionOrder {
    public static func isNewer(marketing: String, build: String, installedMarketing: String, installedBuild: String) -> Bool {
        if marketing.isEmpty || installedMarketing.isEmpty {
            return !build.isEmpty && compare(installedBuild, build) == .orderedAscending
        }
        let order = compare(installedMarketing, marketing)
        return order == .orderedAscending || (order == .orderedSame && compare(installedBuild, build) == .orderedAscending)
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = tokenize(lhs)
        let right = tokenize(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftPart = index < left.count ? left[index] : .number(0)
            let rightPart = index < right.count ? right[index] : .number(0)
            if leftPart == rightPart { continue }
            return leftPart < rightPart ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private enum Part: Equatable, Comparable {
        case number(Int)
        case text(String)

        static func < (lhs: Part, rhs: Part) -> Bool {
            switch (lhs, rhs) {
            case let (.number(left), .number(right)):
                return left < right
            case let (.text(left), .text(right)):
                return left.localizedStandardCompare(right) == .orderedAscending
            case (.number, .text):
                return false
            case (.text, .number):
                return true
            }
        }
    }

    private static func tokenize(_ value: String) -> [Part] {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        let pattern = #"([0-9]+|[a-z]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return [.text(normalized)]
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        return expression.matches(in: normalized, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: normalized) else { return nil }
            let token = String(normalized[swiftRange])
            if let number = Int(token) { return .number(number) }
            return .text(token)
        }
    }
}
