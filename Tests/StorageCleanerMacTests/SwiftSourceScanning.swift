import Foundation
import XCTest

/// Source-guard helpers (D98). `code(_:)` blanks comments and the contents of
/// string literals, keeping delimiters, interpolated code and line breaks, so
/// a call named in documentation or a message never counts as code. It keeps
/// every unicode scalar in place, so a range found there covers the same text
/// in the raw source, which `compactKeepingLiterals(_:)` compares exactly.
/// `body(of:in:)` finds a body by matching braces, not by searching for the
/// next declaration's name.
enum SwiftSourceScanning {
    static var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Repository-relative path to the raw text of every Swift file in `Sources`.
    static func sources() throws -> [String: String] {
        let root = projectRoot.standardizedFileURL.path
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: projectRoot.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
        var result: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result[String(url.standardizedFileURL.path.dropFirst(root.count + 1))] =
                try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    /// `code(_:)` of every file in `sources()`, lexed once per test run.
    static func sourceCode() throws -> [String: String] { try lexed.get() }

    /// `compact(_:)` of every file in `sourceCode()`.
    static func compactSourceCode() throws -> [String: String] { try compacted.get() }

    private static let lexed = Result { try sources().mapValues(code) }
    private static let compacted = Result { try lexed.get().mapValues(compact) }

    static func code(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: zip(text.unicodeScalars, parts(of: text)).map { scalar, part in
            part == .code || scalar == "\n" ? scalar : " "
        })
        return String(view)
    }

    /// Comments and the whitespace outside string literals removed, literal
    /// contents kept exactly, so `"Info. plist"` never reads as `"Info.plist"`.
    /// `text` starts outside any comment or literal.
    static func compactKeepingLiterals(_ text: String) -> String {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var view = String.UnicodeScalarView()
        for (scalar, part) in zip(text.unicodeScalars, parts(of: text))
        where part == .literal || (part == .code && !whitespace.contains(scalar)) {
            view.append(scalar)
        }
        return String(view)
    }

    private enum Part { case code, comment, literal }

    /// What each unicode scalar of `text` belongs to; literal delimiters and
    /// interpolated code are code.
    private static func parts(of text: String) -> [Part] {
        enum Mode { case code, interpolation(depth: Int), string(hashes: Int, multiline: Bool) }
        let input = Array(text.unicodeScalars)
        var output = [Part](repeating: .code, count: input.count)
        var stack: [Mode] = [.code]
        var index = 0
        func at(_ position: Int) -> Unicode.Scalar? { position < input.count ? input[position] : nil }
        func mark(_ range: Range<Int>, as part: Part) {
            for position in range.clamped(to: 0..<input.count) { output[position] = part }
        }
        /// `count` copies of `scalar` start at `position`.
        func run(of scalar: Unicode.Scalar, _ count: Int, at position: Int) -> Bool {
            position + count <= input.count && (0..<count).allSatisfy { input[position + $0] == scalar }
        }
        while index < input.count {
            let scalar = input[index]
            switch stack[stack.count - 1] {
            case .code, .interpolation:
                if scalar == "/", at(index + 1) == "/" {
                    var end = index
                    while end < input.count, input[end] != "\n" { end += 1 }
                    mark(index..<end, as: .comment)
                    index = end
                } else if scalar == "/", at(index + 1) == "*" {
                    var depth = 0, end = index
                    repeat {
                        if input[end] == "/", at(end + 1) == "*" { depth += 1; end += 2 }
                        else if input[end] == "*", at(end + 1) == "/" { depth -= 1; end += 2 }
                        else { end += 1 }
                    } while depth > 0 && end < input.count
                    mark(index..<end, as: .comment)
                    index = end
                } else if scalar == "#" || scalar == "\"" {
                    var quote = index
                    while quote < input.count, input[quote] == "#" { quote += 1 }
                    guard at(quote) == "\"" else { index = max(quote, index + 1); continue }
                    let multiline = run(of: "\"", 3, at: quote)
                    stack.append(.string(hashes: quote - index, multiline: multiline))
                    index = quote + (multiline ? 3 : 1)
                } else {
                    if case let .interpolation(depth) = stack[stack.count - 1] {
                        if scalar == "(" {
                            stack[stack.count - 1] = .interpolation(depth: depth + 1)
                        } else if scalar == ")" {
                            if depth == 0 { stack.removeLast() } else { stack[stack.count - 1] = .interpolation(depth: depth - 1) }
                        }
                    }
                    index += 1
                }
            case let .string(hashes, multiline):
                let quotes = multiline ? 3 : 1
                if scalar == "\"", run(of: "\"", quotes, at: index), run(of: "#", hashes, at: index + quotes) {
                    stack.removeLast()
                    index += quotes + hashes
                } else if scalar == "\\", run(of: "#", hashes, at: index + 1) {
                    let escaped = index + 1 + hashes
                    if at(escaped) == "(" {
                        stack.append(.interpolation(depth: 0))
                        index = escaped + 1
                    } else {
                        mark(index..<escaped + 1, as: .literal)
                        index = escaped + 1
                    }
                } else if !multiline, scalar == "\n" {
                    stack.removeLast() // An unterminated literal never swallows the rest of the file.
                } else {
                    mark(index..<index + 1, as: .literal)
                    index += 1
                }
            }
        }
        return output
    }

    /// The text inside the braces of the first `{` at or after `marker`.
    static func body(of marker: String, in code: some StringProtocol,
                     file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let code = String(code)
        let start = try XCTUnwrap(code.range(of: marker), "missing \(marker)", file: file, line: line)
        let range = try XCTUnwrap(bodyRange(from: start.lowerBound, in: code), "no body after \(marker)",
                                  file: file, line: line)
        return String(code[range])
    }

    static func bodyRange(from start: String.Index, in code: String) -> Range<String.Index>? {
        guard let open = code[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "{" {
                depth += 1
            } else if code[index] == "}" {
                depth -= 1
                if depth == 0 { return code.index(after: open)..<index }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// The body of the innermost function, initializer or deinitializer around
    /// `position`: the first `{` after the balanced parameter list, so a
    /// closure default argument is never taken for the body. A declaration
    /// without a body (a `}` comes first, as in a protocol) is skipped.
    static func enclosingFunctionBody(of position: String.Index, in code: String) -> Range<String.Index>? {
        let declaration = try! NSRegularExpression(
            pattern: #"\b(?:func\s+[^\s(<]+\s*(?:<[^{(]*>)?\s*\(|init[?!]?\s*(?:<[^{(]*>)?\s*\(|deinit\b)"#)
        for match in declaration.matches(in: code, range: NSRange(code.startIndex..<position, in: code)).reversed() {
            guard let start = Range(match.range, in: code) else { continue }
            var index = start.upperBound
            if code[start].last == "(" {
                var depth = 1
                while index < code.endIndex, depth > 0 {
                    if code[index] == "(" { depth += 1 } else if code[index] == ")" { depth -= 1 }
                    index = code.index(after: index)
                }
            }
            guard let open = code[index...].firstIndex(of: "{"), !code[index..<open].contains("}"),
                  let body = bodyRange(from: open, in: code), body.contains(position) else { continue }
            return body
        }
        return nil
    }

    /// Whitespace removed, so a statement reads the same in any layout.
    static func compact(_ text: some StringProtocol) -> String {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.lazy.filter { !whitespace.contains($0) })
        return String(view)
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
