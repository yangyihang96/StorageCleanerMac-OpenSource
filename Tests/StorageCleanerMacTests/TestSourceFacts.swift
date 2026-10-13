import Foundation

/// Tests 源码守卫的词法数据流。位置均为 UTF-16；不执行被检查的源码。
/// 同一执行边界内按可达赋值解析；跨闭包及类型成员保守合并，局部遮蔽仍生效。
/// 缓存仅属于本份源码，递归上下文是键的一部分。
final class TestSourceFacts {
    struct Value {
        var standard = false
        var shared = false
        var live = false
        // Retained for diagnostic provenance and the legacy Library-only red
        // mutation. The actual write decision uses only unisolatedHome.
        var homeComponents: [String]?
        var unknownHomeComponent = false
        var containsParentTraversal = false
        // A presentation path can contain `..` without coming from a home root.
        // Keep this proof after an escaping append invalidates isolation.
        var homeParentTraversal = false
        var isolated = false
        var ownershipChecked = false
        var unisolatedHome = false
        // A model may contain a fictitious /Users path or an enum called
        // `.standard`. Keep write-path taint separate from proven live sources.
        var runtimeHome = false
        var persistentSingleton = false
        var stringConstantAmbiguous = false
        var mayBeNil = false
        var nilOnly = false
        var stringConstant: String?
        var isUnisolatedHome: Bool { unisolatedHome }
        var isUnsafeWritePath: Bool { unisolatedHome }
        var isRealLibrary: Bool { homeComponents?.first == "Library" }
        var hasLiveDefault: Bool { standard || shared || live }
        mutating func merge(_ other: Value) {
            standard = standard || other.standard
            shared = shared || other.shared
            live = live || other.live
            mayBeNil = mayBeNil || other.mayBeNil
            nilOnly = nilOnly || other.nilOnly
            isolated = isolated || other.isolated
            ownershipChecked = ownershipChecked || other.ownershipChecked
            unisolatedHome = unisolatedHome || other.unisolatedHome
            runtimeHome = runtimeHome || other.runtimeHome
            persistentSingleton = persistentSingleton || other.persistentSingleton
            unknownHomeComponent = unknownHomeComponent || other.unknownHomeComponent
            containsParentTraversal = containsParentTraversal || other.containsParentTraversal
            homeParentTraversal = homeParentTraversal || other.homeParentTraversal
            if let lhs = stringConstant, let rhs = other.stringConstant, lhs != rhs { stringConstantAmbiguous = true }
            stringConstantAmbiguous = stringConstantAmbiguous || other.stringConstantAmbiguous
            if stringConstantAmbiguous { stringConstant = nil }
            else if stringConstant == nil { stringConstant = other.stringConstant }
            if other.isRealLibrary || homeComponents == nil { homeComponents = other.homeComponents }
        }
    }
    struct Scope {
        var range: NSRange
        let parent: Int?
        var function: String?
        var isType = false
        var isExtension = false
        var isClosure = false
    }
    struct Binding {
        let name: String
        let type: String?
        let scope: Int
        let position: Int
        let expression: NSRange?
        let declaration: Bool
        var optional = false
        var member = false
        var parameter = false
    }
    struct Call {
        let range: NSRange
        let arguments: [String: NSRange]
        var typeIsExplicit = true
    }

    let code: String
    let literals: String
    private(set) var scopes: [Scope] = []
    private var bindings: [Binding] = []
    private var bindingsByName: [String: [Int]] = [:]
    private let units: [UInt16]
    private let codeText: NSString
    private let literalText: NSString
    private var scopeLookup: [Int] = []
    private var closingLookup: [Int: Int] = [:]
    private var argumentOpeningByBrace: [Int: Int] = [:]
    private var assignmentsByDeclaration: [Int: [Int]] = [:]
    private var typeAliases: [String: String] = [:]
    private var constructorCache: [String: [Call]] = [:]
    private var argumentCache: [Int: [String: NSRange]] = [:]
    private lazy var inferredInitializers = Self.matches(#"\.\s*init\s*\("#, in: code)
    private var reachingCache: [BindingPosition: [Int]] = [:]
    private var factsCache: [FactsKey: Value] = [:]
    private var resolvedCache: [ResolvedKey: Value] = [:]
    private var statementBodyCache: [Bool?] = []
    private var storageCandidateCache: [NSRange: Bool] = [:]
    private var parameterDefaultLocations = Set<Int>()
    private static let contextualConstructorLabels: [String: String] = [
        "UserDefaults": "preferences|scanHistoryDefaults|cleanupPreferences|defaults",
        "SystemEnergyAccumulator": "systemEnergyAccumulator",
        "MenuBarSamplingGaps": "samplingGaps",
        "ScanHeavyWorkService.Operations": "scanHeavyWorkOperations|operations",
        "FanControlCoordinator": "fanControl",
        "ComputerHealthStore": "computerHealthStore",
        "PrivilegedBatteryPowerModeCommandRunner": "powerModeWriter"
    ]
    private static let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted
    private static let storageCodeMarkers = ["standard", "shared", "home", "Home", "HOME", "Users", "..",
                       "Directory", "userDomainMask", "pw_dir", "PathSafety",
                       "applicationSupportRoot", "defaultURL", "expandingTildeInPath"]
    private static let storageLiteralMarkers = ["HOME", "Users", "..", "~/"]
    // Aliases can only inherit sources present in this same immutable file.
    // Include every expression-source marker, not just UserDefaults/home names.
    private lazy var fileMayHaveStorageSource = Self.storageCodeMarkers.contains { code.contains($0) }
        || Self.storageLiteralMarkers.contains { literals.contains($0) }
    private(set) var factsEvaluationCount = 0

    private struct BindingPosition: Hashable { let declared: Int; let position: Int }
    private struct FactsKey: Hashable { let range: NSRange; let position: Int?; let visited: Set<Int> }
    private struct ResolvedKey: Hashable { let name: String; let position: Int; let member: Bool; let visited: Set<Int> }

    init(code: String, literals: String) {
        self.code = code
        self.literals = literals
        units = Array(code.utf16)
        codeText = code as NSString
        literalText = literals as NSString
        var delimiters: [(position: Int, closing: UInt16)] = []
        let pairs: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125]
        for (position, unit) in units.enumerated() {
            if let close = pairs[unit] {
                if unit == 123, let argument = delimiters.last(where: { $0.closing == 41 || $0.closing == 93 }) {
                    argumentOpeningByBrace[position] = argument.position
                }
                delimiters.append((position, close))
            }
            else if unit == delimiters.last?.closing, let opening = delimiters.popLast() {
                closingLookup[opening.position] = position
            }
        }
        scopes = [Scope(range: NSRange(location: 0, length: units.count), parent: nil)]
        var stack = [0]
        for (position, unit) in units.enumerated() {
            if unit == 123 {
                let scope = Scope(range: NSRange(location: position, length: units.count - position), parent: stack.last)
                scopes.append(scope)
                stack.append(scopes.count - 1)
            } else if unit == 125, stack.count > 1, let index = stack.popLast() {
                scopes[index].range.length = position - scopes[index].range.location + 1
            }
        }
        // Same innermost-brace semantics as the old reverse scope scan, in O(1) per query.
        scopeLookup = Array(repeating: 0, count: units.count + 1)
        let openings = Dictionary(uniqueKeysWithValues: scopes.indices.dropFirst().map { (scopes[$0].range.location, $0) })
        var active = [0]
        for position in units.indices {
            while active.count > 1, let last = active.last, position >= NSMaxRange(scopes[last].range) { active.removeLast() }
            if let opening = openings[position] { active.append(opening) }
            scopeLookup[position] = active.last ?? 0
        }
        for match in Self.matches(#"\b(?:class|struct|enum|extension)\s+[\w.]+[^{}]*\{"#, in: code) {
            if let index = openings[NSMaxRange(match.range) - 1] {
                scopes[index].isType = true
                scopes[index].isExtension = text(match.range).hasPrefix("extension")
            }
        }
        for match in Self.matches(#"\btypealias\s+(\w+)\s*=\s*([\w.]+)"#, in: code) {
            typeAliases[text(match.range(at: 1))] = text(match.range(at: 2))
        }
        statementBodyCache = Array(repeating: nil, count: scopes.count)
        for match in Self.matches(#"\b(?:let|var)\s+(\w+)"#, in: code) {
            let name = text(match.range(at: 1))
            var cursor = NSMaxRange(match.range)
            while cursor < units.count && Self.isHorizontalSpace(units[cursor]) { cursor += 1 }
            var annotation = ""
            if cursor < units.count && units[cursor] == 58 {
                let start = cursor + 1
                cursor = start
                while cursor < units.count {
                    if Self.isParenOrBracket(units[cursor]), let end = closing(cursor) { cursor = end + 1; continue }
                    if Self.isAnnotationEnd(units[cursor]) { break }
                    cursor += 1
                }
                annotation = text(NSRange(location: start, length: cursor - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let optional = annotation.hasSuffix("?") || annotation.hasSuffix("!")
            let named = optional ? String(annotation.dropLast()) : annotation
            let type = Self.matches(#"\A[\w.]+\z"#, in: named).isEmpty ? nil : named
            let expression = cursor < units.count && units[cursor] == 61
                ? expressionRange(from: cursor + 1, stopsAtControlBody: isConditionalBinding(at: match.range.location)) : nil
            bindings.append(Binding(name: name, type: type, scope: scope(at: match.range.location),
                                    position: match.range.location, expression: expression, declaration: true, optional: optional))
        }
        let declarationExpressions = Set(bindings.compactMap { $0.expression?.location })
        for match in Self.matches(#"(?<![\w.])(?:self\s*\.\s*)?\b(\w+)\s*=(?!=)"#, in: code) {
            let name = text(match.range(at: 1))
            let expression = expressionRange(from: NSMaxRange(match.range))
            if declarationExpressions.contains(expression.location) { continue }
            bindings.append(Binding(name: name, type: nil, scope: scope(at: match.range.location),
                                    position: match.range.location, expression: expression, declaration: false,
                                    member: !Self.matches(#"\Aself\s*\."#, in: text(match.range)).isEmpty))
        }
        // 形参即使没有默认值也必须遮蔽外层同名属性。
        for match in Self.matches(#"\b(?:func\s+(\w+)|init)\s*\("#, in: code) {
            let preceding = codeText.rangeOfCharacter(from: Self.nonWhitespace, options: .backwards,
                                                       range: NSRange(location: 0, length: match.range.location))
            if preceding.location != NSNotFound && units[preceding.location] == 46 { continue }
            guard let close = closing(NSMaxRange(match.range) - 1),
                  let body = units[(close + 1)...].firstIndex(of: 123),
                  let index = openings[body] else { continue }
            scopes[index].function = match.range(at: 1).location == NSNotFound ? "init" : text(match.range(at: 1))
            for range in argumentRanges(after: NSMaxRange(match.range)) {
                addParameter(range, scope: index, position: body)
            }
        }
        // 常见闭包形参和显式捕获列表。捕获值在父作用域计算。
        for index in scopes.indices.dropFirst() where scopes[index].function == nil && !scopes[index].isType {
            guard !isStatementBody(index) else { continue }
            let start = scopes[index].range.location + 1
            let head = text(NSRange(location: start, length: min(scopes[index].range.length - 2, 500)))
            guard let header = Self.matches(#"\A\s*+(?:@\w+\s+)*(?:\[([^\]]*)\]\s*)?\(?([\w\s,:?.]*)\)?\s*(?:async\s*)?(?:throws\s*)?(?:->\s*[\w.]+\s*)?in\b"#, in: head).first else { continue }
            scopes[index].isClosure = true
            if header.range(at: 1).location != NSNotFound {
                let capture = NSRange(location: start + header.range(at: 1).location, length: header.range(at: 1).length)
                for part in split(capture) {
                    let fragment = text(part)
                    guard let entry = Self.matches(#"\A\s*(?:weak\s+|unowned\s+)?(\w+)\s*(?:=\s*([\s\S]*))?\z"#, in: fragment).first else { continue }
                    let name = (fragment as NSString).substring(with: entry.range(at: 1))
                    let value = entry.range(at: 2).location == NSNotFound
                        ? NSRange(location: part.location + entry.range(at: 1).location, length: entry.range(at: 1).length)
                        : NSRange(location: part.location + entry.range(at: 2).location, length: entry.range(at: 2).length)
                    bindings.append(Binding(name: name, type: nil, scope: index, position: start - 1,
                                            expression: value, declaration: true))
                }
            }
            let parameters = NSRange(location: start + header.range(at: 2).location, length: header.range(at: 2).length)
            for part in split(parameters) { addParameter(part, scope: index, position: start - 1) }
        }
        for index in scopes.indices.dropFirst() where scopes[index].function == nil && !scopes[index].isType {
            guard !isStatementBody(index) else { continue }
            var preceding = scopes[index].range.location - 1
            while preceding >= 0 && Self.isSpace(units[preceding]) { preceding -= 1 }
            let startsValue = preceding >= 0 && Self.isValueStart(units[preceding])
                && !(units[preceding] == 61 && preceding > 0 && Self.isComparisonPrefix(units[preceding - 1]))
            let line: String
            if startsValue { line = "" }
            else {
                let end = scopes[index].range.location
                let start = lastLineStart(before: end, lowerBound: max(0, end - 160))
                line = text(NSRange(location: start, length: end - start))
            }
            if startsValue || !Self.matches(#"(?:\w+|\))\s*(?:in)?\s*\z"#, in: line).isEmpty {
                scopes[index].isClosure = true
            }
        }
        // A parameter default is a declaration source, not an assignment to an
        // outer member. The early assignment scan also sees its `=` token.
        let parameterDefaults = Set(bindings.filter(\.parameter).compactMap { $0.expression?.location })
        parameterDefaultLocations = parameterDefaults
        bindings.removeAll { !$0.declaration && $0.expression.map { parameterDefaults.contains($0.location) } == true }
        for index in bindings.indices { bindingsByName[bindings[index].name, default: []].append(index) }
        // Resolve each assignment once. Local/parameter shadowing and explicit self
        // are handled here, before whole-type member sources are conservatively merged.
        for index in bindings.indices where !bindings[index].declaration {
            let entry = bindings[index]
            if let declared = binding(entry.name, at: entry.position, declarationOnly: true, memberOnly: entry.member) {
                assignmentsByDeclaration[declared, default: []].append(index)
            }
        }
        for key in Array(assignmentsByDeclaration.keys) {
            assignmentsByDeclaration[key]?.sort { bindings[$0].position < bindings[$1].position }
        }
    }

    func text(_ range: NSRange, strings: Bool = false) -> String {
        (strings ? literalText : codeText).substring(with: range)
    }
    func scope(at position: Int) -> Int {
        scopeLookup.indices.contains(position) ? scopeLookup[position] : 0
    }
    func initializer(of name: String, before position: Int) -> NSRange? {
        binding(name, at: position).flatMap { bindings[$0].expression }
    }
    func firstArgument(after start: Int) -> NSRange? { argumentRanges(after: start).first }
    func function(at position: Int) -> String? {
        var index: Int? = scope(at: position)
        while let current = index {
            if let name = scopes[current].function { return name }
            index = scopes[current].parent
        }
        return nil
    }
    private func isAncestor(_ ancestor: Int, of child: Int) -> Bool {
        var index: Int? = child
        while let current = index {
            if current == ancestor { return true }
            index = scopes[current].parent
        }
        return false
    }
    private func binding(_ name: String, at position: Int, declarationOnly: Bool = false, memberOnly: Bool = false) -> Int? {
        let current = scope(at: position)
        let declarations = bindingsByName[name, default: []].lazy.filter { [self] in
            bindings[$0].name == name && bindings[$0].declaration
                && (bindings[$0].position < position || scopes[bindings[$0].scope].isType)
                && (!memberOnly || scopes[bindings[$0].scope].isType)
                && isAncestor(bindings[$0].scope, of: current)
        }
        guard let declared = declarations.max(by: {
            (bindings[$0].scope, bindings[$0].position) < (bindings[$1].scope, bindings[$1].position)
        }) else { return nil }
        if declarationOnly { return declared }
        return reachingBindings(for: declared, at: position).last ?? declared
    }

    private func executionBoundary(_ scope: Int) -> Int {
        var index: Int? = scope
        while let current = index {
            if scopes[current].function != nil || scopes[current].isClosure { return current }
            index = scopes[current].parent
        }
        return 0
    }

    /// A declaration shadows an outer name. An assignment instead changes its
    /// resolved declaration; conditional exits preserve every possible source.
    private func reachingBindings(for declared: Int, at position: Int) -> [Int] {
        let key = BindingPosition(declared: declared, position: position)
        if let cached = reachingCache[key] { return cached }
        let candidates = assignmentsByDeclaration[declared, default: []]
        if scopes[bindings[declared].scope].isType {
            // setUp/init and any other method can run before this use. Never let
            // source ordering or a later safe assignment erase a hazardous member source.
            let result = [declared] + candidates
            reachingCache[key] = result
            return result
        }
        let current = scope(at: position)
        let boundary = executionBoundary(current)
        let declaredBoundary = executionBoundary(bindings[declared].scope)
        if boundary != declaredBoundary || candidates.contains(where: { executionBoundary(bindings[$0].scope) != declaredBoundary }) {
            // A closure can execute after its textual use and mutate a captured
            // local. Without call-order analysis, keep all sources of this exact
            // declaration, including later writes; never merge shadowing locals.
            let result = [declared] + candidates
            reachingCache[key] = result
            return result
        }
        let assignments = candidates.filter {
            bindings[$0].position > bindings[declared].position && bindings[$0].position < position
                && executionBoundary(bindings[$0].scope) == boundary
        }
        var result = [declared]
        for index in assignments {
            if isAncestor(bindings[index].scope, of: current) { result = [index] }
            else { result.append(index) }
        }
        reachingCache[key] = result
        return result
    }

    private func resolved(_ name: String, at position: Int, member: Bool, visited: Set<Int>) -> Value {
        let key = ResolvedKey(name: name, position: position, member: member, visited: visited)
        if let cached = resolvedCache[key] { return cached }
        let result = uncachedResolved(name, at: position, member: member, visited: visited)
        resolvedCache[key] = result
        return result
    }

    private func uncachedResolved(_ name: String, at position: Int, member: Bool, visited: Set<Int>) -> Value {
        guard let declared = binding(name, at: position, declarationOnly: true, memberOnly: member) else { return Value() }
        var result = Value()
        var firstSource = true
        for index in reachingBindings(for: declared, at: position) where !visited.contains(index) && visited.count < 40 {
            let entry = bindings[index]
            var next = visited; next.insert(index)
            var value = entry.expression.map { facts(in: $0, before: entry.position, visited: next) } ?? Value()
            if let expression = entry.expression, canonicalType(entry.type ?? bindings[declared].type ?? "") == "URL",
               !Self.matches(#"\A\s*\.\s*homeDirectory\b"#, in: text(expression)).isEmpty {
                value.unisolatedHome = true
                value.runtimeHome = true
                value.homeComponents = []
            }
            if let expression = entry.expression, value.standard || value.shared,
               let access = Self.matches(#"\A\s*\.\s*(standard|shared)\b"#, in: text(expression)).first {
                let member = text(NSRange(location: expression.location + access.range(at: 1).location,
                                          length: access.range(at: 1).length))
                if isPersistentSingleton(type: bindingType(declared), member: member) {
                    value.persistentSingleton = true
                }
            }
            // An optional parameter/annotation can still receive nil even when its
            // default expression is nonnil; only an explicit ?? fallback discharges it.
            value.mayBeNil = value.mayBeNil || entry.optional
            if entry.parameter && entry.optional { value.nilOnly = false }
            let allIsolated = firstSource ? value.isolated : result.isolated && value.isolated
            let allChecked = firstSource ? value.ownershipChecked : result.ownershipChecked && value.ownershipChecked
            let allNil = firstSource ? value.nilOnly : result.nilOnly && value.nilOnly
            if !firstSource && result.stringConstant != value.stringConstant { result.stringConstantAmbiguous = true }
            result.merge(value)
            result.isolated = allIsolated
            result.ownershipChecked = allChecked
            result.nilOnly = allNil
            firstSource = false
        }
        return result
    }
    func facts(in range: NSRange, before position: Int? = nil, visited: Set<Int> = []) -> Value {
        let key = FactsKey(range: range, position: position, visited: visited)
        if let cached = factsCache[key] { return cached }
        factsEvaluationCount += 1
        let result = uncachedFacts(in: range, before: position, visited: visited)
        factsCache[key] = result
        return result
    }

    private func uncachedFacts(in range: NSRange, before position: Int?, visited: Set<Int>) -> Value {
        if let inner = parenthesizedContent(in: range) { return facts(in: inner, before: position, visited: visited) }
        if let append = completePathAppend(in: range) {
            let base = facts(in: append.base, before: position, visited: visited)
            let component = facts(in: append.component, before: position, visited: visited)
            var result = base
            result.merge(component)
            // Only constants without a parent-directory segment can preserve the
            // receiver's isolation. A `..` segment may escape even an owned home.
            let componentText = text(append.component).trimmingCharacters(in: .whitespacesAndNewlines)
            let literalComponent = text(append.component, strings: true).trimmingCharacters(in: .whitespacesAndNewlines)
            let parentTraversal = component.containsParentTraversal
            result.homeParentTraversal = result.homeParentTraversal || (parentTraversal
                && (base.unisolatedHome || base.runtimeHome || base.isolated || base.ownershipChecked))
            let constantComponent = component.stringConstant != nil && !parentTraversal
                && (!Self.matches(#"\A"[^"\\]*"\z"#, in: literalComponent).isEmpty
                    || !Self.matches(#"\A(?:self\s*\.\s*)?\w+\z"#, in: componentText).isEmpty)
            result.unisolatedHome = base.unisolatedHome
                || (component.unisolatedHome && !constantComponent)
                || parentTraversal
            result.unknownHomeComponent = result.unknownHomeComponent || parentTraversal
            if parentTraversal { result.isolated = false; result.ownershipChecked = false }
            result.stringConstant = nil
            return result
        }
        let fragment = text(range)
        let literal = text(range, strings: true)
        if let branches = topLevelTernary(in: range) {
            var result = facts(in: branches.condition, before: position, visited: visited)
            let yes = facts(in: branches.yes, before: position, visited: visited)
            let no = facts(in: branches.no, before: position, visited: visited)
            result.merge(yes); result.merge(no)
            result.mayBeNil = yes.mayBeNil || no.mayBeNil
            result.nilOnly = yes.nilOnly && no.nilOnly
            result.ownershipChecked = (yes.nilOnly || yes.ownershipChecked) && (no.nilOnly || no.ownershipChecked)
            result.isolated = yes.isolated && no.isolated
            result.stringConstant = yes.stringConstant == no.stringConstant ? yes.stringConstant : nil
            return result
        }
        // Handle top-level coalescing before merging aliases. A safe nonoptional
        // fallback proves nonnil; hazardous sources on either side remain visible.
        if let split = topLevelCoalescing(in: range) {
            var result = facts(in: split.0, before: position, visited: visited)
            let fallback = facts(in: split.1, before: position, visited: visited)
            let constant = result.nilOnly || result.stringConstant == fallback.stringConstant ? fallback.stringConstant : nil
            let checkedOnEveryPath = (result.nilOnly || result.ownershipChecked) && fallback.ownershipChecked
            result.merge(fallback)
            result.ownershipChecked = checkedOnEveryPath
            result.nilOnly = fallback.nilOnly
            result.mayBeNil = fallback.mayBeNil
            result.stringConstant = constant
            return result
        }
        var result = Value(
            standard: !Self.matches(#"\.\s*standard\b"#, in: fragment).isEmpty,
            shared: !Self.matches(#"\.\s*shared\b"#, in: fragment).isEmpty,
            live: !Self.matches(#"\.\s*live\b"#, in: fragment).isEmpty
        )
        if result.standard || result.shared {
            for access in Self.matches(#"\b([A-Z][\w.]*)\s*\.\s*(standard|shared)\b"#, in: fragment) {
                let type = canonicalType((fragment as NSString).substring(with: access.range(at: 1)))
                let member = (fragment as NSString).substring(with: access.range(at: 2))
                if isPersistentSingleton(type: type, member: member) { result.persistentSingleton = true }
            }
        }
        result.mayBeNil = !Self.matches(#"\A\s*\(*\s*nil\s*\)*\s*\z"#, in: fragment).isEmpty
        result.nilOnly = result.mayBeNil
        result.mayBeNil = result.mayBeNil || !Self.matches(#"\btry\s*\?|\bas\s*\?|\?\s*\."#, in: fragment).isEmpty
        let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        if let constant = Self.matches(#"\A"([^"\\]*)"\z"#, in: trimmed).first {
            result.stringConstant = (trimmed as NSString).substring(with: constant.range(at: 1))
            result.containsParentTraversal = result.stringConstant?.split(separator: "/").contains("..") == true
        }
        result.isolated = !Self.matches(#"\bTestFileSystem\s*\.\s*(?:requireOwned(?:Data)?|makeHome|makeOperationHome|uniqueRoot|uniqueOperationRoot)\s*\("#, in: fragment).isEmpty
        result.ownershipChecked = !Self.matches(#"\bTestFileSystem\s*\.\s*requireOwned(?:Data)?\s*\("#, in: fragment).isEmpty
        var pathStart = 0
        if let home = Self.matches(#"\bhomeDirectoryForCurrentUser\b|\bhomeDirectory\s*\(\s*forUser\s*:|\bNSHomeDirectory(?:ForUser)?\s*\(|\bpw_dir\b|\bURL\s*\.\s*(?:homeDirectory|desktopDirectory|documentsDirectory|downloadsDirectory|libraryDirectory|cachesDirectory|applicationSupportDirectory|trashDirectory|moviesDirectory|musicDirectory|picturesDirectory)\b|\bPathSafety\s*\.\s*(?:homePath|lexicalHomePath)"#, in: fragment).first {
            result.homeComponents = []
            result.unisolatedHome = true
            result.runtimeHome = true
            pathStart = NSMaxRange(home.range)
        }
        if !Self.matches(#"\bNSSearchPathForDirectoriesInDomains\s*\([^)]*\.\s*userDomainMask\b"#, in: fragment).isEmpty
            || !Self.matches(#"\benvironment\s*\[\s*"HOME"\s*\]|\bgetenv\s*\(\s*"HOME"\s*\)"#, in: literal).isEmpty {
            result.unisolatedHome = true
            result.runtimeHome = true
            result.homeComponents = []
        }
        if fragment.contains("userDomainMask") {
            let directories = ["cachesDirectory": "Caches", "applicationSupportDirectory": "Application Support",
                               "libraryDirectory": "", "preferencePanesDirectory": "PreferencePanes",
                               "applicationScriptsDirectory": "Application Scripts", "autosavedInformationDirectory": "Autosave Information"]
            if !Self.matches(#"\bfor\s*:\s*\.\s*\w+Directory\b"#, in: fragment).isEmpty {
                result.unisolatedHome = true
                result.runtimeHome = true
                result.homeComponents = []
            }
            for (directory, suffix) in directories where !Self.matches(#"\bfor\s*:\s*\.\s*"# + directory + #"\b"#, in: fragment).isEmpty {
                result.homeComponents = ["Library"] + (suffix.isEmpty ? [] : [suffix])
                result.unisolatedHome = true
                result.runtimeHome = true
            }
        }
        if !Self.matches(#"\b(?:AppDataDirectories\s*\.\s*applicationSupportRoot|(?:SystemEnergyAccumulatorLocation|MenuBarPowerHistoryStore)\s*\.\s*defaultURL)\b"#, in: fragment).isEmpty {
            result.homeComponents = ["Library", "Application Support"]
            result.unisolatedHome = true
            result.runtimeHome = true
        }
        if !Self.matches(#"(?:"~/|"/Users/|\.\s*expandingTildeInPath\b)"#, in: literal).isEmpty {
            result.unisolatedHome = true
            result.homeComponents = result.homeComponents ?? []
        }
        // Resolve local aliases and explicit members separately, preserving shadowing.
        let argumentLabels = argumentLabelLocations(in: range)
        for word in Self.matches(#"(?<![\w.])\b[A-Za-z_]\w*\b"#, in: fragment) {
            let name = (fragment as NSString).substring(with: word.range)
            let absolute = range.location + word.range.location
            // A constructor's `store:` label is not a reference to an outer
            // `let store`. Its value is still scanned, including `store: store`.
            if argumentLabels.contains(absolute) { continue }
            let resolved = self.resolved(name, at: position ?? absolute, member: false, visited: visited)
            if result.homeComponents == nil, resolved.homeComponents != nil { pathStart = NSMaxRange(word.range) }
            result.merge(resolved)
        }
        for reference in Self.matches(#"\bself\s*\.\s*(\w+)"#, in: fragment) {
            let name = (fragment as NSString).substring(with: reference.range(at: 1))
            let resolved = self.resolved(name, at: position ?? range.location + reference.range.location, member: true, visited: visited)
            if result.homeComponents == nil, resolved.homeComponents != nil { pathStart = NSMaxRange(reference.range) }
            result.merge(resolved)
        }
        if result.homeComponents != nil {
            let suffix = (literal as NSString).substring(from: pathStart)
            // appendingPathComponent arguments can be local string constants.
            let codeSuffix = (fragment as NSString).substring(from: pathStart)
            for addition in Self.matches(#"\.\s*appendingPathComponent\s*\("#, in: codeSuffix) {
                let start = range.location + pathStart + NSMaxRange(addition.range)
                guard let argument = firstArgument(after: start) else { continue }
                let component = facts(in: argument, before: position, visited: visited)
                if let value = component.stringConstant {
                    result.homeComponents?.append(contentsOf: value.split(separator: "/").map(String.init))
                } else { result.unknownHomeComponent = true }
            }
            let additions = Self.matches(#"\+\s*"/([^"\n]*)"|\)/((?:Library)[^"\n]*)""#, in: suffix)
            for addition in additions {
                let group = (1...2).first { addition.range(at: $0).location != NSNotFound }!
                let path = (suffix as NSString).substring(with: addition.range(at: group))
                result.homeComponents?.append(contentsOf: path.split(separator: "/").map(String.init))
            }
        }
        // Checked ownership wrappers and explicit constructors return nonoptional
        // values even when an optional input appears inside their argument list.
        if !Self.matches(#"\A\s*(?:try!?\s+)?(?:await\s+)?(?:TestFileSystem\s*\.\s*requireOwned(?:Data)?|[A-Z]\w*)\s*\("#, in: fragment).isEmpty {
            result.mayBeNil = false
            result.nilOnly = false
        }
        if !Self.matches(#"\A\s*(?:try[!?]?\s+)?TestFileSystem\s*\.\s*requireOwned(?:Data)?\s*\("#, in: fragment).isEmpty {
            result.unisolatedHome = false
        }
        // Constant provenance must describe the whole value, not a literal
        // mentioned inside an unrelated call/property expression.
        if Self.matches(#"\A"[^"\\]*"\z"#, in: trimmed).isEmpty
            && Self.matches(#"\A\s*(?:self\s*\.\s*)?\w+\s*\z"#, in: fragment).isEmpty {
            result.stringConstant = nil
        }
        if let url = Self.matches(#"\A\s*URL\s*\("#, in: fragment).first {
            let opening = range.location + NSMaxRange(url.range) - 1
            if let end = closing(opening), end < NSMaxRange(range),
               !Self.matches(#"\A\s*\.\s*lastPathComponent\s*\z"#,
                             in: text(NSRange(location: end + 1, length: NSMaxRange(range) - end - 1))).isEmpty,
               let input = arguments(after: opening + 1)["fileURLWithPath"],
               let path = facts(in: input, before: position, visited: visited).stringConstant {
                let leaf = (path as NSString).lastPathComponent
                if !leaf.isEmpty && leaf != "." && leaf != ".." {
                    // A known constant URL filename is a component, not a root.
                    // Unknown objects/inputs and traversal components stay tainted.
                    result.unisolatedHome = false
                    result.homeComponents = nil
                    result.stringConstant = leaf
                } else if leaf == ".." {
                    result.unisolatedHome = true
                    result.unknownHomeComponent = true
                }
            }
        }
        if isClosureValue(in: range) {
            result.mayBeNil = false
            result.nilOnly = false
        }
        if result.persistentSingleton,
           let read = Self.matches(#"\A\s*(?:(?:NS)?UserDefaults\s*\.\s*standard|(?:self\s*\.\s*)?\w+)\s*\.\s*(?:object|string|bool|integer|float|double|data|array|dictionary|stringArray|url|volatileDomain|persistentDomain|dictionaryRepresentation)\s*\("#, in: fragment).first {
            let opening = range.location + NSMaxRange(read.range) - 1
            if let close = closing(opening), close < NSMaxRange(range),
               text(NSRange(location: close + 1, length: NSMaxRange(range) - close - 1))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A complete read call returns data, not the defaults object.
                // Leave the old standard/write-path flags intact for sinks.
                result.persistentSingleton = false
            }
        }
        return result
    }

    /// Optional values inside a closure body describe execution, not whether the
    /// injected closure exists. Only a complete literal gets this nonnil proof.
    private func isClosureValue(in range: NSRange) -> Bool {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end && Self.isSpace(units[start]) { start += 1 }
        while end > start && Self.isSpace(units[end - 1]) { end -= 1 }
        return start < end && units[start] == 123 && closing(start) == end - 1
    }

    /// Locate labels only inside parentheses and directly after `(` or `,`.
    /// Dictionary keys and expressions on the value side remain references.
    private func argumentLabelLocations(in range: NSRange) -> Set<Int> {
        var labels = Set<Int>()
        var openings: [UInt16] = []
        for index in range.location..<NSMaxRange(range) {
            let unit = units[index]
            if Self.isOpeningDelimiter(unit) { openings.append(unit) }
            else if Self.isClosingDelimiter(unit) { _ = openings.popLast() }
            else if unit == 58, openings.last == 40 {
                var end = index
                while end > range.location && Self.isSpace(units[end - 1]) { end -= 1 }
                var start = end
                while start > range.location {
                    let character = units[start - 1]
                    guard character == 95 || (48...57).contains(character)
                        || (65...90).contains(character) || (97...122).contains(character) else { break }
                    start -= 1
                }
                var prefix = start
                while prefix > range.location && Self.isSpace(units[prefix - 1]) { prefix -= 1 }
                if start < end, prefix > range.location, Self.isArgumentDelimiter(units[prefix - 1]) {
                    labels.insert(start)
                }
            }
        }
        return labels
    }

    private func parenthesizedContent(in range: NSRange) -> NSRange? {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end && Self.isSpace(units[start]) { start += 1 }
        while end > start && Self.isSpace(units[end - 1]) { end -= 1 }
        guard start < end, units[start] == 40, closing(start) == end - 1 else { return nil }
        return NSRange(location: start + 1, length: end - start - 2)
    }

    private func topLevelCoalescing(in range: NSRange) -> (NSRange, NSRange)? {
        var index = range.location
        while index + 1 < NSMaxRange(range) {
            if Self.isOpeningDelimiter(units[index]), let end = closing(index) { index = end + 1; continue }
            if units[index] == 63 && units[index + 1] == 63 {
                return (NSRange(location: range.location, length: index - range.location),
                        NSRange(location: index + 2, length: NSMaxRange(range) - index - 2))
            }
            index += 1
        }
        return nil
    }

    private func completePathAppend(in range: NSRange) -> (base: NSRange, component: NSRange)? {
        var end = NSMaxRange(range)
        while end > range.location && Self.isSpace(units[end - 1]) { end -= 1 }
        let fragment = text(range)
        for match in Self.matches(#"\.\s*(appendingPathComponent|appending)\s*\("#, in: fragment) {
            let opening = range.location + NSMaxRange(match.range) - 1
            guard let close = closing(opening), close < end,
                  !Self.matches(#"\A\s*(?:\.\s*(?:path|standardizedFileURL))*\s*\z"#,
                                in: text(NSRange(location: close + 1, length: end - close - 1))).isEmpty else { continue }
            let component = text(NSRange(location: range.location + match.range(at: 1).location, length: match.range(at: 1).length)) == "appending"
                ? arguments(after: opening + 1)["path"] : firstArgument(after: opening + 1)
            guard let component else { continue }
            let base = NSRange(location: range.location, length: match.range.location)
            return (base, component)
        }
        return nil
    }

    private func topLevelTernary(in range: NSRange) -> (condition: NSRange, yes: NSRange, no: NSRange)? {
        var question: Int?
        var nesting = 0
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            if Self.isOpeningDelimiter(units[index]), let close = closing(index) { index = close + 1; continue }
            if units[index] == 63 && (index == range.location || units[index - 1] != 63)
                && (index + 1 == end || !Self.isPostfixStart(units[index + 1])) {
                if question == nil { question = index }
                nesting += 1
            } else if units[index] == 58, let question {
                nesting -= 1
                if nesting == 0 {
                    return (NSRange(location: range.location, length: question - range.location),
                            NSRange(location: question + 1, length: index - question - 1),
                            NSRange(location: index + 1, length: end - index - 1))
                }
            }
            index += 1
        }
        return nil
    }

    /// 显式 Type(...)、Type.init(...)、带类型的 .init(...)、后续赋值与函数返回 .init。
    func constructors(of type: String) -> [Call] {
        if let cached = constructorCache[type] { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: type)
        let namedTypes = ([type] + typeAliases.keys.filter { canonicalType($0) == type }).sorted()
        var starts = Set<Int>()
        if namedTypes.contains(where: { code.contains($0) }) {
            let names = namedTypes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            starts = Set(Self.matches(#"\b(?:"# + names + #")\s*(?:\.\s*init\s*)?\("#, in: code).map { NSMaxRange($0.range) })
        }
        var contextualStarts = Set<Int>()
        if !inferredInitializers.isEmpty, let labels = Self.contextualConstructorLabels[type] {
            for match in Self.matches(#"\b(?:"# + labels + #")\s*:\s*\.\s*init\s*\("#, in: code) {
                let start = NSMaxRange(match.range)
                if !starts.contains(start) { contextualStarts.insert(start) }
                starts.insert(start)
            }
        }
        for match in inferredInitializers {
            let location = match.range.location
            if let bound = bindings.first(where: { binding in
                guard let value = binding.expression, NSLocationInRange(location, value) else { return false }
                let prefix = text(NSRange(location: value.location, length: location - value.location))
                return !Self.matches(#"\A\s*(?:try[!?]?\s+)?(?:await\s+)?\z"#, in: prefix).isEmpty
            }), (canonicalType(bound.type ?? "") == type || binding(bound.name, at: bound.position, declarationOnly: true).map { canonicalType(bindings[$0].type ?? "") == type } == true) {
                starts.insert(NSMaxRange(match.range))
                contextualStarts.remove(NSMaxRange(match.range))
            }
            let enclosing = scopes[scope(at: location)]
            if enclosing.function != nil {
                let prefix = text(NSRange(location: max(0, enclosing.range.location - 200), length: min(200, enclosing.range.location)))
                let bodyPrefix = text(NSRange(location: enclosing.range.location + 1, length: location - enclosing.range.location - 1))
                if !Self.matches(#"->\s*"# + escaped + #"[!?]?\s*\z"#, in: prefix).isEmpty,
                   !Self.matches(#"\A\s*(?:return\s+)?\z"#, in: bodyPrefix).isEmpty {
                    starts.insert(NSMaxRange(match.range))
                    contextualStarts.remove(NSMaxRange(match.range))
                }
            }
        }
        let result = starts.sorted().map { start in
            Call(range: NSRange(location: start, length: 0), arguments: arguments(after: start),
                 typeIsExplicit: !contextualStarts.contains(start))
        }
        constructorCache[type] = result
        return result
    }
    /// One full-code pass finds every existing sink; no file or method is omitted.
    func calls(named methods: Set<String>) -> [(name: String, call: Call)] {
        let alternatives = methods.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return Self.matches(#"\b("# + alternatives + #")\s*\("#, in: code).map { match in
            (name: text(match.range(at: 1)),
             call: Call(range: match.range, arguments: arguments(after: NSMaxRange(match.range))))
        }
    }

    func calls(matching pattern: String) -> [Call] {
        Self.matches(pattern, in: code).map { Call(range: $0.range, arguments: arguments(after: NSMaxRange($0.range))) }
    }

    /// Only simple aliases are resolved, with a cycle guard. This is not a Swift
    /// type checker; generic aliases, imported aliases and object identity remain unknown.
    private func canonicalType(_ name: String) -> String {
        var current = name
        var seen = Set<String>()
        while seen.insert(current).inserted, let next = typeAliases[current] { current = next }
        if current.hasPrefix("Foundation.") { current = String(current.dropFirst("Foundation.".count)) }
        return current
    }

    private func bindingType(_ index: Int) -> String {
        let entry = bindings[index]
        if let type = entry.type { return canonicalType(type) }
        guard let expression = entry.expression,
              let constructor = Self.matches(#"\A\s*(?:try[!?]?\s+)?(?:await\s+)?([A-Z][\w.]*)\s*\("#, in: text(expression)).first else { return "" }
        let name = text(NSRange(location: expression.location + constructor.range(at: 1).location, length: constructor.range(at: 1).length))
        return canonicalType(name.hasSuffix(".init") ? String(name.dropLast(5)) : name)
    }

    private func isPersistentSingleton(type: String, member: String) -> Bool {
        if member == "standard" { return ["UserDefaults", "NSUserDefaults"].contains(type) }
        return member == "shared" && ["FanControlCoordinator", "BatteryHealthRuntime",
            "GeekDashboardConfigurationStore", "MenuBarStatusController",
            "MenuBarSamplingGaps", "SystemEnergyAccumulator"].contains(type)
    }

    func hasUnsafeSingletonAccess() -> Bool {
        guard code.contains("shared") else { return false }
        let types: Set<String> = ["FanControlCoordinator", "BatteryHealthRuntime", "GeekDashboardConfigurationStore", "MenuBarStatusController"]
        for access in Self.matches(#"\b([A-Z][\w.]*)\s*\.\s*shared\b"#, in: code) {
            if types.contains(canonicalType(text(access.range(at: 1)))) { return true }
        }
        // Default parameters and reassignment may use contextual `.shared`.
        // The declaration's annotation or constructor supplies its known type.
        for index in bindings.indices {
            let entry = bindings[index]
            guard let expression = entry.expression else { continue }
            let fragment = text(expression)
            guard fragment.contains("shared"),
                  !Self.matches(#"\.\s*shared\b"#, in: fragment).isEmpty else { continue }
            let declared = entry.declaration ? index : binding(entry.name, at: entry.position, declarationOnly: true, memberOnly: entry.member)
            if let declared, types.contains(bindingType(declared)) { return true }
        }
        return false
    }

    /// A standard-domain default is safe only when every occurrence of the
    /// parameter is a known read receiver. Aliases, escapes and unknown methods
    /// keep the old rejection; comments/literals are already masked. Treat
    /// ambiguous same-name bindings conservatively instead of guessing effects.
    func isReadOnlyPreferenceParameter(defaultIn range: NSRange) -> Bool {
        guard let entry = bindings.first(where: {
            $0.parameter && $0.expression.map { NSLocationInRange($0.location, range) } == true
        }), let expression = entry.expression,
           scopes[entry.scope].function != nil,
           !Self.matches(#"\A\s*(?:(?:NS)?UserDefaults\s*)?\.\s*standard\s*\z"#, in: text(expression)).isEmpty else { return false }
        let bodyScope = scopes[entry.scope].range
        guard closing(bodyScope.location) == NSMaxRange(bodyScope) - 1 else { return false }
        let body = NSRange(location: bodyScope.location + 1, length: bodyScope.length - 2)
        let fragment = text(body)
        let name = NSRegularExpression.escapedPattern(for: entry.name)
        let labels = argumentLabelLocations(in: body)
        let reads = Self.matches(#"\b"# + name + #"\b\s*[?!]?\s*\.\s*(object|string|bool|integer|float|double|data|array|dictionary|stringArray|url|volatileDomain|persistentDomain|dictionaryRepresentation)\s*\("#, in: fragment)
        var readReceivers = Set<Int>()
        for read in reads {
            let opening = body.location + NSMaxRange(read.range) - 1
            guard let close = closing(opening), close < NSMaxRange(body) else { continue }
            let method = (fragment as NSString).substring(with: read.range(at: 1))
            if method == "dictionaryRepresentation" {
                guard text(NSRange(location: opening + 1, length: close - opening - 1), strings: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            } else {
                let label = ["volatileDomain", "persistentDomain"].contains(method) ? "forName" : "forKey"
                guard argumentRanges(after: opening + 1).count == 1,
                      let value = arguments(after: opening + 1)[label],
                      !text(value, strings: true).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            }
            readReceivers.insert(body.location + read.range.location)
        }
        // Check every reference, including read-call arguments and nested bodies.
        // A preceding harmless read cannot hide a later object escape or write.
        return Self.matches(#"\b"# + name + #"\b"#, in: fragment).allSatisfy {
            let position = body.location + $0.range.location
            return labels.contains(position) || readReceivers.contains(position)
        }
    }

    /// Cheap conservative coverage for known cross-type gaps: reject a hazardous
    /// stored entry at its definition/assignment instead of guessing its receiver.
    /// Ordinary resolved members retain the existing sink/whole-type analysis.
    func unsafeStorageSources() -> [NSRange] {
        guard fileMayHaveStorageSource else { return [] }
        var sources: [NSRange] = []
        let parameterDefaults = parameterDefaultLocations
        func enclosingType(_ scope: Int) -> Int? {
            var index: Int? = scope
            while let current = index {
                if scopes[current].isType { return current }
                index = scopes[current].parent
            }
            return nil
        }
        func hazardous(_ expression: NSRange) -> Bool {
            guard mayHaveStorageSource(in: expression) else { return false }
            let value = facts(in: expression)
            // Definitions and unresolved members use the same proven sources
            // as another object's property; enum values and read results are data.
            return value.persistentSingleton || (value.runtimeHome && value.isUnisolatedHome)
                || (value.homeParentTraversal && value.isUnisolatedHome)
        }
        for entry in bindings {
            // `_ = value` discards a result; it never creates a stored entry.
            // Calls inside the RHS still participate in the independent sink scan.
            guard entry.name != "_", let expression = entry.expression else { continue }
            if entry.declaration {
                // Local declarations cannot define static/extension storage.
                guard scopes[entry.scope].isType else { continue }
                let start = max(scopes[entry.scope].range.location, entry.position - 160)
                let prefix = text(NSRange(location: start, length: entry.position - start))
                let isStatic = (prefix.contains("static") || prefix.contains("class"))
                    && !Self.matches(#"\b(?:static|class)\b[^;{}\n]*\z"#, in: prefix).isEmpty
                if (isStatic || scopes[entry.scope].isExtension) && hazardous(expression) { sources.append(expression) }
            } else if binding(entry.name, at: entry.position, declarationOnly: true, memberOnly: entry.member) == nil,
                      enclosingType(entry.scope) != nil,
                      hazardous(expression) {
                // Includes unqualified extension/inherited member assignments.
                sources.append(expression)
            }
        }
        for assignment in Self.matches(#"(?<![\w.])\b(?!self\b|case\b)\w+(?:\s*\.\s*\w+)+\s*=(?!=)"#, in: code) {
            let expression = expressionRange(from: NSMaxRange(assignment.range))
            // A qualified parameter annotation (e.g. Fixture.Direction = ...)
            // is not a property target. Its default is checked at actual sinks.
            if parameterDefaults.contains(expression.location) { continue }
            guard mayHaveStorageSource(in: expression) else { continue }
            let value = facts(in: expression)
            // Other objects also hold presentation URLs and pure enum values.
            // Reject proven runtime roots/singletons here; every filesystem sink
            // still checks literal and aliased /Users paths independently.
            if value.persistentSingleton || (value.runtimeHome && value.isUnisolatedHome)
                || (value.homeParentTraversal && value.isUnisolatedHome) {
                sources.append(expression)
            }
        }
        return sources
    }

    /// A negative result only skips facts for source-free, unbound expressions.
    /// Any binding name keeps full alias/member, branch and late-write analysis.
    private func mayHaveStorageSource(in range: NSRange) -> Bool {
        if let cached = storageCandidateCache[range] { return cached }
        let fragment = text(range)
        let direct: Bool
        if Self.storageCodeMarkers.contains(where: { fragment.contains($0) }) { direct = true }
        else {
            let literal = text(range, strings: true)
            direct = Self.storageLiteralMarkers.contains { literal.contains($0) }
        }
        let hasBinding = !direct && Self.matches(#"\b\w+\b"#, in: fragment).contains { word in
            bindingsByName[text(NSRange(location: range.location + word.range.location,
                                        length: word.range.length))] != nil
        }
        let result = direct || hasBinding
        storageCandidateCache[range] = result
        return result
    }

    func arguments(after start: Int) -> [String: NSRange] {
        if let cached = argumentCache[start] { return cached }
        var result: [String: NSRange] = [:]
        for part in argumentRanges(after: start) {
            guard let label = Self.matches(#"\A\s*(\w+)\s*:"#, in: text(part)).first else { continue }
            let name = (text(part) as NSString).substring(with: label.range(at: 1))
            result[name] = NSRange(location: part.location + NSMaxRange(label.range), length: part.length - NSMaxRange(label.range))
        }
        argumentCache[start] = result
        return result
    }
    private func addParameter(_ range: NSRange, scope: Int, position: Int) {
        let part = text(range)
        guard let match = Self.matches(#"\A\s*(?:\w+\s+)?(\w+)\s*(?::\s*([\w.]+)[!?]?)?"#, in: part).first else { return }
        let name = (part as NSString).substring(with: match.range(at: 1))
        guard name != "_" else { return }
        let type = match.range(at: 2).location == NSNotFound ? nil : (part as NSString).substring(with: match.range(at: 2))
        let assignment = Self.matches(#"=(?!=)"#, in: part).first
        let value = assignment.map { NSRange(location: range.location + NSMaxRange($0.range), length: range.length - NSMaxRange($0.range)) }
        bindings.append(Binding(name: name, type: type, scope: scope, position: position, expression: value, declaration: true,
                                optional: part.components(separatedBy: "=").first.map { $0.contains("?") || $0.contains("!") } == true, parameter: true))
    }

    // Switches avoid temporary arrays and iterator allocations in Debug loops.
    private static func isHorizontalSpace(_ unit: UInt16) -> Bool {
        switch unit { case 9, 32: return true; default: return false }
    }
    private static func isSpace(_ unit: UInt16) -> Bool {
        switch unit { case 9, 10, 13, 32: return true; default: return false }
    }
    private static func isParenOrBracket(_ unit: UInt16) -> Bool {
        switch unit { case 40, 91: return true; default: return false }
    }
    private static func isOpeningDelimiter(_ unit: UInt16) -> Bool {
        switch unit { case 40, 91, 123: return true; default: return false }
    }
    private static func isClosingDelimiter(_ unit: UInt16) -> Bool {
        switch unit { case 41, 93, 125: return true; default: return false }
    }
    private static func isAnnotationEnd(_ unit: UInt16) -> Bool {
        switch unit { case 10, 13, 44, 59, 61, 123, 125: return true; default: return false }
    }
    private static func isValueStart(_ unit: UInt16) -> Bool {
        switch unit { case 40, 44, 58, 61, 91: return true; default: return false }
    }
    private static func isComparisonPrefix(_ unit: UInt16) -> Bool {
        switch unit { case 33, 60, 61, 62: return true; default: return false }
    }
    private static func isArgumentDelimiter(_ unit: UInt16) -> Bool {
        switch unit { case 40, 44: return true; default: return false }
    }
    private static func isPostfixStart(_ unit: UInt16) -> Bool {
        switch unit { case 40, 46, 63, 91: return true; default: return false }
    }
    private static func isExpressionEnd(_ unit: UInt16) -> Bool {
        switch unit { case 44, 59, 125: return true; default: return false }
    }

    private func lastLineStart(before end: Int, lowerBound: Int) -> Int {
        var cursor = end
        while cursor > lowerBound {
            switch units[cursor - 1] {
            case 10, 59, 123, 125: return cursor
            default: cursor -= 1
            }
        }
        return lowerBound
    }

    private func closing(_ opening: Int) -> Int? {
        closingLookup[opening]
    }
    private func argumentRanges(after start: Int) -> [NSRange] {
        guard let end = closing(start - 1) else { return [] }
        return split(NSRange(location: start, length: end - start))
    }
    private func split(_ range: NSRange) -> [NSRange] {
        var parts: [NSRange] = []
        var start = range.location
        var index = start
        while index < NSMaxRange(range) {
            if Self.isOpeningDelimiter(units[index]), let end = closing(index) { index = end + 1; continue }
            if units[index] == 44 { parts.append(NSRange(location: start, length: index - start)); start = index + 1 }
            index += 1
        }
        parts.append(NSRange(location: start, length: NSMaxRange(range) - start))
        return parts
    }
    /// A conditional binding's following brace starts statements, not its RHS.
    /// Parenthesized calls/closure arguments are skipped normally; assignments in
    /// the body still participate in the independent whole-source sink scan.
    private func isStatementBody(_ index: Int) -> Bool {
        if let cached = statementBodyCache[index] { return cached }
        let result = uncachedStatementBody(index)
        statementBodyCache[index] = result
        return result
    }

    private func uncachedStatementBody(_ index: Int) -> Bool {
        let end = scopes[index].range.location
        if let argument = argumentOpeningByBrace[end], let parent = scopes[index].parent,
           argument > scopes[parent].range.location { return false }
        let start = max(0, end - 500)
        var statementStart = start
        var omitted: [NSRange] = []
        var cursor = start
        while cursor < end {
            switch units[cursor] {
            case 40, 91:
                if let close = closing(cursor), close < end {
                    omitted.append(NSRange(location: cursor, length: close - cursor + 1))
                    cursor = close + 1
                    continue
                }
            case 59, 123, 125:
                statementStart = cursor + 1
                omitted.removeAll(keepingCapacity: true)
            default: break
            }
            cursor += 1
        }
        // Only the final statement is materialized. One space has the same word
        // boundaries as the old equal-length masking; source offsets stay intact.
        var statement = ""
        cursor = statementStart
        for range in omitted {
            statement += text(NSRange(location: cursor, length: range.location - cursor)) + " "
            cursor = NSMaxRange(range)
        }
        statement += text(NSRange(location: cursor, length: end - cursor))
        return !Self.matches(#"\b(?:if|else|for|while|switch|do|catch|guard|repeat|defer)\b[^{};]*\z"#, in: statement).isEmpty
    }

    private func isConditionalBinding(at position: Int) -> Bool {
        var end = position
        while end > 0 && Self.isSpace(units[end - 1]) { end -= 1 }
        var start = end
        while start > 0 {
            let unit = units[start - 1]
            guard (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) else { break }
            start -= 1
        }
        if ["if", "guard", "while"].contains(text(NSRange(location: start, length: end - start))) { return true }
        guard end > 0 && units[end - 1] == 44 else { return false }
        // Only later conditional clauses need a prefix scan; ordinary bindings
        // keep the short adjacent-keyword path.
        let beginning = scopes[scope(at: position)].range.location
        let prefix = text(NSRange(location: beginning, length: position - beginning))
        return !Self.matches(#"\b(?:if|guard|while)\b[^;{}]*,\s*\z"#, in: prefix).isEmpty
    }

    private func expressionRange(from start: Int, stopsAtControlBody: Bool = false) -> NSRange {
        var index = start
        while index < units.count {
            if stopsAtControlBody && units[index] == 123 { break }
            if Self.isOpeningDelimiter(units[index]), let end = closing(index) { index = end + 1; continue }
            if Self.isExpressionEnd(units[index]) { break }
            if units[index] == 10 {
                var next = index + 1
                while next < units.count && Self.isSpace(units[next]) { next += 1 }
                let continues = next < units.count && (units[next] == 46
                    || (units[next] == 63 && next + 1 < units.count && units[next + 1] == 63))
                if !continues { break }
            }
            index += 1
        }
        return NSRange(location: start, length: index - start)
    }
    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        TestSourceRegex.matches(pattern, in: text)
    }
}

/// Immutable compiled expressions are shared; per-source facts never escape their
/// analysis instance. The lock covers cache mutation, not regex matching.
enum TestSourceRegex {
    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var expressions: [String: NSRegularExpression] = [:]
        func expression(_ pattern: String) -> NSRegularExpression {
            lock.withLock {
                if let existing = expressions[pattern] { return existing }
                let expression = try! NSRegularExpression(pattern: pattern)
                expressions[pattern] = expression
                return expression
            }
        }
    }
    static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        cache.expression(pattern).matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}
