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

        let observedSince = Date()
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
        return parse(result.standardOutput, generatedAt: Date(), observedSince: observedSince)
    }

    static func parse(
        _ output: String,
        generatedAt: Date,
        observedSince: Date? = nil,
        metadataResolver: ((Int32, Date) -> ProcessMetadata?)? = nil
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

        // Resolve only the Top-K numeric range. Include the complete boundary
        // tie because the existing final tiebreaker uses localized app names.
        let cutoff = parsedRows.count > 5 ? parsedRows[4] : nil
        let candidates = parsedRows.prefix { row in
            guard let cutoff else { return true }
            return row.totalBytesPerSecond > cutoff.totalBytesPerSecond
                || (row.totalBytesPerSecond == cutoff.totalBytesPerSecond
                    && row.downloadBytesPerSecond >= cutoff.downloadBytesPerSecond)
        }
        let resolve = metadataResolver ?? resolveMetadata
        let resolved = candidates.map { row in
            let metadata = resolve(row.processIdentifier, observedSince ?? generatedAt)
            return NativeNetworkProcessTransfer(processIdentifier: row.processIdentifier,
                name: metadata?.name ?? row.name, iconPath: metadata?.iconPath ?? "",
                downloadBytesPerSecond: row.downloadBytesPerSecond,
                uploadBytesPerSecond: row.uploadBytesPerSecond)
        }.sorted(by: processSort)
        return NativeNetworkProcessSnapshot(generatedAt: generatedAt, processes: Array(resolved.prefix(5)))
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

        return NativeNetworkProcessTransfer(processIdentifier: processIdentifier,
            name: fallbackName, iconPath: "", downloadBytesPerSecond: downloadBytes,
            uploadBytesPerSecond: uploadBytes)
    }

    struct ProcessMetadata {
        let name: String?
        let iconPath: String
    }

    private static func processBirth(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private static func resolveMetadata(_ pid: Int32, observedSince: Date) -> ProcessMetadata? {
        guard let birth = processBirth(pid),
              Double(birth) / 1_000_000 <= observedSince.timeIntervalSince1970 else { return nil }
        let application = NSRunningApplication(processIdentifier: pid)
        let name = application?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = resolvedApplicationIconPath(bundlePath: application?.bundleURL?.path,
            executablePath: application?.executableURL?.path ?? processExecutablePath(for: pid))
        // Exit or PID reuse during metadata resolution leaves the nettop label
        // intact, without assigning the replacement process's name/icon.
        guard processBirth(pid) == birth else { return nil }
        return ProcessMetadata(name: name.flatMap { $0.isEmpty ? nil : $0 }, iconPath: path)
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
