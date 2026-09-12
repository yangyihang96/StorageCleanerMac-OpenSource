import Foundation

enum LaunchdPlistParserError: Error, Equatable {
    case malformedPropertyList
    case invalidRootObject
}

struct LaunchdPlistParser: Sendable {
    func parse(
        data: Data,
        plistURL: URL? = nil,
        applicationBundleURL: URL? = nil
    ) throws -> StartupItemsDomain.LaunchdConfiguration {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw LaunchdPlistParserError.malformedPropertyList
        }
        guard let dictionary = object as? [String: Any] else {
            throw LaunchdPlistParserError.invalidRootObject
        }
        return parse(dictionary: dictionary, plistURL: plistURL, applicationBundleURL: applicationBundleURL)
    }

    func parse(
        dictionary: [String: Any],
        plistURL: URL? = nil,
        applicationBundleURL: URL? = nil
    ) -> StartupItemsDomain.LaunchdConfiguration {
        var issues = [StartupItemsDomain.ParseIssue]()
        let label = nonemptyString(dictionary["Label"])
        if label == nil { issues.append(.missingLabel) }

        let program = nonemptyString(dictionary["Program"])
        let arguments = stringArray(dictionary["ProgramArguments"], key: "ProgramArguments", issues: &issues)
        let bundleProgram = nonemptyString(dictionary["BundleProgram"])
        let executableURL = resolvedExecutableURL(
            program: program,
            arguments: arguments,
            bundleProgram: bundleProgram,
            applicationBundleURL: applicationBundleURL,
            issues: &issues
        )
        if program == nil, arguments.first == nil, bundleProgram == nil {
            issues.append(.missingExecutable)
        }

        let runAtLoad = bool(dictionary["RunAtLoad"], key: "RunAtLoad", issues: &issues)
        let keepAlive = parseKeepAlive(dictionary["KeepAlive"], issues: &issues)
        let interval = integer(dictionary["StartInterval"], key: "StartInterval", issues: &issues)
        let calendar = parseCalendarIntervals(dictionary["StartCalendarInterval"], issues: &issues)
        let watchPaths = stringArray(dictionary["WatchPaths"], key: "WatchPaths", issues: &issues)
        let queueDirectories = stringArray(dictionary["QueueDirectories"], key: "QueueDirectories", issues: &issues)
        let sockets = namedDictionaryKeys(dictionary["Sockets"], key: "Sockets", issues: &issues)
        let machServices = namedDictionaryKeys(dictionary["MachServices"], key: "MachServices", issues: &issues)
        let sessionTypes = stringOrArray(dictionary["LimitLoadToSessionType"], key: "LimitLoadToSessionType", issues: &issues)
        let associatedIdentifiers = stringOrArray(dictionary["AssociatedBundleIdentifiers"], key: "AssociatedBundleIdentifiers", issues: &issues)

        let triggers = launchTriggers(
            plistURL: plistURL,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive.boolValue,
            interval: interval,
            calendar: calendar,
            watchPaths: watchPaths,
            queueDirectories: queueDirectories,
            sockets: sockets,
            machServices: machServices,
            sessionTypes: sessionTypes
        )

        return StartupItemsDomain.LaunchdConfiguration(
            label: label,
            program: program,
            programArguments: arguments,
            bundleProgram: bundleProgram,
            resolvedExecutableURL: executableURL,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive.boolValue,
            keepAliveDictionary: keepAlive.dictionary,
            startInterval: interval,
            startCalendarIntervals: calendar,
            watchPaths: watchPaths,
            queueDirectories: queueDirectories,
            sockets: sockets,
            machServices: machServices,
            disabled: bool(dictionary["Disabled"], key: "Disabled", issues: &issues),
            processType: nonemptyString(dictionary["ProcessType"]),
            limitLoadToSessionTypes: sessionTypes,
            associatedBundleIdentifiers: associatedIdentifiers,
            workingDirectory: nonemptyString(dictionary["WorkingDirectory"]),
            userName: nonemptyString(dictionary["UserName"]),
            groupName: nonemptyString(dictionary["GroupName"]),
            standardOutPath: nonemptyString(dictionary["StandardOutPath"]),
            standardErrorPath: nonemptyString(dictionary["StandardErrorPath"]),
            triggers: triggers,
            rawValues: dictionary.compactMapValues(Self.propertyListValue),
            issues: issues
        )
    }

    private func resolvedExecutableURL(
        program: String?,
        arguments: [String],
        bundleProgram: String?,
        applicationBundleURL: URL?,
        issues: inout [StartupItemsDomain.ParseIssue]
    ) -> URL? {
        if let program {
            guard program.hasPrefix("/") else {
                issues.append(.invalidValue(key: "Program"))
                return nil
            }
            return URL(fileURLWithPath: program).standardizedFileURL
        }
        if let first = arguments.first {
            guard first.hasPrefix("/") else {
                issues.append(.invalidValue(key: "ProgramArguments"))
                return nil
            }
            return URL(fileURLWithPath: first).standardizedFileURL
        }
        if let bundleProgram {
            guard let applicationBundleURL else {
                issues.append(.unresolvedBundleProgram(bundleProgram))
                return nil
            }
            guard !bundleProgram.hasPrefix("/"), !bundleProgram.split(separator: "/").contains("..") else {
                issues.append(.unresolvedBundleProgram(bundleProgram))
                return nil
            }
            return applicationBundleURL.appendingPathComponent(bundleProgram).standardizedFileURL
        }
        return nil
    }

    private func parseKeepAlive(
        _ value: Any?,
        issues: inout [StartupItemsDomain.ParseIssue]
    ) -> (boolValue: Bool?, dictionary: [String: String]) {
        guard let value else { return (nil, [:]) }
        if let boolean = value as? Bool { return (boolean, [:]) }
        if let dictionary = value as? [String: Any] {
            return (
                dictionary.isEmpty ? false : true,
                dictionary.mapValues(Self.scalarDescription)
            )
        }
        issues.append(.invalidValue(key: "KeepAlive"))
        return (nil, [:])
    }

    private func parseCalendarIntervals(
        _ value: Any?,
        issues: inout [StartupItemsDomain.ParseIssue]
    ) -> [StartupItemsDomain.CalendarSchedule] {
        guard let value else { return [] }
        let dictionaries: [[String: Any]]
        if let dictionary = value as? [String: Any] {
            dictionaries = [dictionary]
        } else if let array = value as? [[String: Any]] {
            dictionaries = array
        } else {
            issues.append(.invalidValue(key: "StartCalendarInterval"))
            return []
        }
        return dictionaries.map {
            StartupItemsDomain.CalendarSchedule(
                minute: Self.losslessInteger($0["Minute"]),
                hour: Self.losslessInteger($0["Hour"]),
                day: Self.losslessInteger($0["Day"]),
                weekday: Self.losslessInteger($0["Weekday"]),
                month: Self.losslessInteger($0["Month"])
            )
        }
    }

    private func launchTriggers(
        plistURL: URL?,
        runAtLoad: Bool?,
        keepAlive: Bool?,
        interval: Int?,
        calendar: [StartupItemsDomain.CalendarSchedule],
        watchPaths: [String],
        queueDirectories: [String],
        sockets: [String],
        machServices: [String],
        sessionTypes: [String]
    ) -> [StartupItemsDomain.LaunchTrigger] {
        var result = [StartupItemsDomain.LaunchTrigger]()
        if sessionTypes.contains(where: { $0.caseInsensitiveCompare("Aqua") == .orderedSame }) {
            result.append(.login)
        } else if plistURL?.path.contains("LaunchDaemons") == true {
            result.append(.systemBoot)
        }
        if runAtLoad == true { result.append(.runAtLoad) }
        if keepAlive == true { result.append(.keepAlive) }
        if let interval, interval > 0 { result.append(.interval(seconds: interval)) }
        if !calendar.isEmpty { result.append(.calendar(calendar)) }
        if !watchPaths.isEmpty { result.append(.watchPaths(watchPaths)) }
        if !queueDirectories.isEmpty { result.append(.queueDirectories(queueDirectories)) }
        if !machServices.isEmpty { result.append(.machServices(machServices)) }
        if !sockets.isEmpty { result.append(.sockets(sockets)) }
        if result.isEmpty { result.append(.onDemand) }
        return result
    }

    private func stringArray(
        _ value: Any?,
        key: String,
        issues: inout [StartupItemsDomain.ParseIssue]
    ) -> [String] {
        guard let value else { return [] }
        guard let values = value as? [Any] else {
            issues.append(.invalidValue(key: key))
            return []
        }
        let strings = values.compactMap { $0 as? String }
        if strings.count != values.count { issues.append(.invalidValue(key: key)) }
        return strings
    }

    private func stringOrArray(
        _ value: Any?,
        key: String,
        issues: inout [StartupItemsDomain.ParseIssue]
    ) -> [String] {
        guard let value else { return [] }
        if let string = nonemptyString(value) { return [string] }
        return stringArray(value, key: key, issues: &issues)
    }

    private func namedDictionaryKeys(
        _ value: Any?,
        key: String,
        issues: inout [StartupItemsDomain.ParseIssue]
    ) -> [String] {
        guard let value else { return [] }
        guard let dictionary = value as? [String: Any] else {
            issues.append(.invalidValue(key: key))
            return []
        }
        return dictionary.keys.sorted()
    }

    private func bool(
        _ value: Any?,
        key: String,
        issues: inout [StartupItemsDomain.ParseIssue]
    ) -> Bool? {
        guard let value else { return nil }
        if let boolean = value as? Bool { return boolean }
        issues.append(.invalidValue(key: key))
        return nil
    }

    private func integer(
        _ value: Any?,
        key: String,
        issues: inout [StartupItemsDomain.ParseIssue]
    ) -> Int? {
        guard let value else { return nil }
        guard let result = Self.losslessInteger(value) else {
            issues.append(.invalidValue(key: key))
            return nil
        }
        return result
    }

    private func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func losslessInteger(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double else { return nil }
            return number.intValue
        }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func scalarDescription(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] { return array.map(scalarDescription).joined(separator: ", ") }
        return String(describing: value)
    }

    private static func propertyListValue(_ value: Any) -> StartupItemsDomain.PropertyListValue? {
        switch value {
        case let value as String: return .string(value)
        case let value as Bool: return .bool(value)
        case let value as Int: return .integer(value)
        case let value as NSNumber:
            let double = value.doubleValue
            return double.rounded() == double ? .integer(value.intValue) : .real(double)
        case let value as Date: return .date(value)
        case let value as Data: return .data(value)
        case let value as [Any]: return .array(value.compactMap(propertyListValue))
        case let value as [String: Any]: return .dictionary(value.compactMapValues(propertyListValue))
        default: return nil
        }
    }
}
