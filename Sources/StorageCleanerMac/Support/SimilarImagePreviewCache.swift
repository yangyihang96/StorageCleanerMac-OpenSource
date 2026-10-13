import AppKit
import Darwin
import ImageIO

/// Read-only, bounded thumbnails for the existing similar-image candidate review.
/// The shared icon cache keeps decoding off the main thread and caps decoded memory.
enum SimilarImagePreviewCache {
    static let shared = AppIconCache(capacity: 96, maximumPending: 32, resultLoader: { path, cancelled in
        load(at: path, isCancelled: cancelled)
    })

    static func decode(at path: String) -> NSImage? { load(at: path).image }

    static func load(
        at path: String,
        reader: GuardedFileContentReader = GuardedFileContentReader(timeout: 5),
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> AppIconCache.LoadedImage {
        do {
            return try reader.withFile(URL(fileURLWithPath: path), isCancelled: isCancelled) { file, control in
                guard file.snapshot.size > 0, file.snapshot.size <= 512 * 1024 * 1024 else {
                    return AppIconCache.LoadedImage(image: nil)
                }
                let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(file.handle.fileDescriptor)")
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(descriptorURL as CFURL, options) else {
                    return AppIconCache.LoadedImage(image: nil)
                }
                try control.check()
                let thumbnailOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                    kCGImageSourceShouldCacheImmediately: false,
                ] as CFDictionary
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
                    return AppIconCache.LoadedImage(image: nil)
                }
                return AppIconCache.LoadedImage(image: NSImage(
                    cgImage: thumbnail,
                    size: NSSize(width: thumbnail.width / 2, height: thumbnail.height / 2)
                ))
            }
        } catch is CancellationError {
            return AppIconCache.LoadedImage(image: nil)
        } catch let error as FileContentReadError {
            return AppIconCache.LoadedImage(image: nil, unavailableReason: error.localizedDescription)
        } catch {
            return AppIconCache.LoadedImage(image: nil, unavailableReason:
                L10n.text("无法读取预览，请在访达中检查文件。", "The preview could not be read. Check the file in Finder."))
        }
    }
}
