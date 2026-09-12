import AppKit
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case invalidArguments
    case noWindows
    case noDisplay
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "usage: capture_app_windows <pid> <output.png> [--exclude-large-windows] [--no-padding]"
        case .noWindows: "no visible application windows found"
        case .noDisplay: "no display contains the application windows"
        case .pngEncodingFailed: "failed to encode screenshot as PNG"
        }
    }
}

@main
enum AppWindowCapture {
    static func main() async {
        do {
            try await capture()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func capture() async throws {
        guard (3...5).contains(CommandLine.arguments.count),
              let processID = pid_t(CommandLine.arguments[1])
        else {
            throw CaptureError.invalidArguments
        }
        let options = CommandLine.arguments.dropFirst(3)
        guard options.allSatisfy({ ["--exclude-large-windows", "--no-padding"].contains($0) }) else {
            throw CaptureError.invalidArguments
        }
        let excludesLargeWindows = options.contains("--exclude-large-windows")
        let padding: CGFloat = options.contains("--no-padding") ? 0 : 8

        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let windows = content.windows.filter { window in
            window.owningApplication?.processID == processID
                && window.frame.width > 100
                && window.frame.height > 100
                && (!excludesLargeWindows || window.frame.width < 1_000)
        }
        guard !windows.isEmpty else { throw CaptureError.noWindows }

        let bounds = windows.reduce(CGRect.null) { $0.union($1.frame) }
        guard let display = content.displays.first(where: { $0.frame.intersects(bounds) }) else {
            throw CaptureError.noDisplay
        }

        let paddedBounds = bounds
            .insetBy(dx: -padding, dy: -padding)
            .intersection(display.frame)
            .integral
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: paddedBounds.minX - display.frame.minX,
            y: paddedBounds.minY - display.frame.minY,
            width: paddedBounds.width,
            height: paddedBounds.height
        )
        // SCDisplay.width can be expressed in logical pixels. Use the actual
        // matching screen's backing scale rather than silently capturing Retina at 1x.
        let displayID = display.displayID
        guard let scale = await MainActor.run(body: {
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }?.backingScaleFactor
        }) else { throw CaptureError.noDisplay }
        configuration.width = Int(paddedBounds.width * scale)
        configuration.height = Int(paddedBounds.height * scale)
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, including: windows)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard let data = NSBitmapImageRep(cgImage: image).representation(
            using: .png,
            properties: [:]
        ) else {
            throw CaptureError.pngEncodingFailed
        }
        try data.write(to: outputURL, options: .atomic)
    }
}
