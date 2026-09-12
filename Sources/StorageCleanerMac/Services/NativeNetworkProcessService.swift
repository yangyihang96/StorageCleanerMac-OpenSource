import AppKit
import Darwin
import Foundation

struct NativeNetworkProcessTransfer: Equatable, Identifiable, Sendable {
    let processIdentifier: Int32
    let name: String
    let iconPath: String
    let downloadBytesPerSecond: Int64
    let uploadBytesPerSecond: Int64

    var id: Int32 { processIdentifier }

    var totalBytesPerSecond: Int64 {
        let (total, overflow) = downloadBytesPerSecond.addingReportingOverflow(
            uploadBytesPerSecond
        )
        return overflow ? Int64.max : total
    }
}

struct NativeNetworkProcessSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let processes: [NativeNetworkProcessTransfer]
}

/// Reads a single one-second delta from macOS' built-in `nettop` utility.
/// Sampling is requested only while the full geek Network detail is visible;
/// the service does not own a timer or a persistent background process.
enum NativeNetworkProcessService {
    static let executablePath = "/usr/bin/nettop"
    static let arguments = [
        "-P", "-L", "2", "-d", "-x", "-n", "-s", "1",
        "-J", "bytes_in,bytes_out",
    ]

    static func snapshot(
        cancellationCheck: @escaping @Sendable () -> Bool = { false }
    ) -> NativeNetworkProcessSnapshot? {
        guard !cancellationCheck() else { return nil }

        let result: ShellCommandResult
        do {
            result = try Shell.run(
                executablePath,
                arguments,
                timeout: 4,
                outputByteLimit: 2 * 1_024 * 1_024,
                cancellationCheck: cancellationCheck
            )
        } catch {
            return nil
        }

        guard result.terminationStatus == 0,
              !cancellationCheck() else { return nil }
        return parse(result.standardOutput, generatedAt: Date())
    }

    static func parse(
        _ output: String,
        generatedAt: Date
    ) -> NativeNetworkProcessSnapshot? {
        let lines = output
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        let headerIndices = lines.indices.filter { lineIndex in
            let line = lines[lineIndex]
            return line.contains("bytes_in") && line.contains("bytes_out")
        }

        // `-L 2 -d` emits a cumulative baseline followed by the one-second
        // delta. Never present the cumulative first block as a transfer rate.
        guard headerIndices.count >= 2,
              let deltaHeaderIndex = headerIndices.last else { return nil }

        let parsedRows = lines[lines.index(after: deltaHeaderIndex)...]
            .compactMap(parseDeltaRow)
            .filter { $0.downloadBytesPerSecond > 0 || $0.uploadBytesPerSecond > 0 }
            .sorted(by: processSort)

        return NativeNetworkProcessSnapshot(
            generatedAt: generatedAt,
            processes: Array(parsedRows.prefix(5))
        )
    }

    private static func parseDeltaRow(_ line: String) -> NativeNetworkProcessTransfer? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false)
        while fields.last?.isEmpty == true {
            fields.removeLast()
        }
        guard fields.count >= 3,
              let downloadBytes = Int64(fields[fields.count - 2]),
              let uploadBytes = Int64(fields[fields.count - 1]),
              downloadBytes >= 0,
              uploadBytes >= 0 else { return nil }

        let rawIdentity = fields.dropLast(2).joined(separator: ",")
        guard let separator = rawIdentity.lastIndex(of: "."),
              let processIdentifier = Int32(rawIdentity[rawIdentity.index(after: separator)...]),
              processIdentifier > 0 else { return nil }

        let fallbackName = rawIdentity[..<separator]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackName.isEmpty else { return nil }

        let runningApplication = NSRunningApplication(
            processIdentifier: processIdentifier
        )
        let name = runningApplication?.localizedName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let displayName = name.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let executablePath = runningApplication?.executableURL?.path
            ?? processExecutablePath(for: processIdentifier)
        let iconPath = resolvedApplicationIconPath(
            bundlePath: runningApplication?.bundleURL?.path,
            executablePath: executablePath
        )

        return NativeNetworkProcessTransfer(
            processIdentifier: processIdentifier,
            name: displayName,
            iconPath: iconPath,
            downloadBytesPerSecond: downloadBytes,
            uploadBytesPerSecond: uploadBytes
        )
    }

    static func resolvedApplicationIconPath(
        bundlePath: String?,
        executablePath: String?
    ) -> String {
        for path in [executablePath, bundlePath].compactMap({ $0 }) {
            if let applicationPath = EnergyImpactService.appBundlePath(in: path) {
                return applicationPath
            }
        }
        return bundlePath ?? executablePath ?? ""
    }

    private static func processExecutablePath(for processIdentifier: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(processIdentifier, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }

    private static func processSort(
        _ lhs: NativeNetworkProcessTransfer,
        _ rhs: NativeNetworkProcessTransfer
    ) -> Bool {
        if lhs.totalBytesPerSecond != rhs.totalBytesPerSecond {
            return lhs.totalBytesPerSecond > rhs.totalBytesPerSecond
        }
        if lhs.downloadBytesPerSecond != rhs.downloadBytesPerSecond {
            return lhs.downloadBytesPerSecond > rhs.downloadBytesPerSecond
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
