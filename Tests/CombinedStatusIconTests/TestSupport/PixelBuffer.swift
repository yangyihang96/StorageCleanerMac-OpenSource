// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/TestSupport/PixelBuffer.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import CoreGraphics
import Foundation
import XCTest
@testable import CombinedStatusIcon

struct PixelBuffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func rgba(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let index = (y * width + x) * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }

    var maximumAlphaOnEdges: UInt8 {
        guard width > 0, height > 0 else { return 0 }

        var maximum: UInt8 = 0
        for x in 0..<width {
            maximum = max(maximum, alphaAt(x: x, y: 0))
            maximum = max(maximum, alphaAt(x: x, y: height - 1))
        }
        if height > 2 {
            for y in 1..<(height - 1) {
                maximum = max(maximum, alphaAt(x: 0, y: y))
                maximum = max(maximum, alphaAt(x: width - 1, y: y))
            }
        }
        return maximum
    }

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &storage,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = storage
    }

    func alpha(atSVGPoint point: CGPoint, size: CGFloat, scale: CGFloat) -> UInt8 {
        guard let pixel = pixelPoint(forSVGPoint: point, size: size, scale: scale) else {
            return 0
        }
        return bytes[(pixel.y * width + pixel.x) * 4 + 3]
    }

    func rgba(
        atSVGPoint point: CGPoint,
        size: CGFloat,
        scale: CGFloat
    ) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        guard let pixel = pixelPoint(forSVGPoint: point, size: size, scale: scale) else {
            return (0, 0, 0, 0)
        }
        return rgba(x: pixel.x, y: pixel.y)
    }

    func alphaSum(inSVGRect rect: CGRect, size: CGFloat, scale: CGFloat) -> Int {
        let pixelsPerSVGUnit = pixelsPerSVGUnit(size: size, scale: scale)
        let minX = max(0, Int((rect.minX * pixelsPerSVGUnit).rounded(.down)))
        let maxX = min(width, Int((rect.maxX * pixelsPerSVGUnit).rounded(.up)))
        let minY = max(0, Int((rect.minY * pixelsPerSVGUnit).rounded(.down)))
        let maxY = min(height, Int((rect.maxY * pixelsPerSVGUnit).rounded(.up)))

        guard minX < maxX, minY < maxY else { return 0 }

        var sum = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                sum += Int(bytes[(y * width + x) * 4 + 3])
            }
        }
        return sum
    }

    func containsColor(
        red: Double,
        green: Double,
        blue: Double,
        tolerance: Double,
        minimumAlpha: Double
    ) -> Bool {
        stride(from: 0, to: bytes.count - 3, by: 4).contains { index in
            let pixelRed = Double(bytes[index]) / 255.0
            let pixelGreen = Double(bytes[index + 1]) / 255.0
            let pixelBlue = Double(bytes[index + 2]) / 255.0
            let pixelAlpha = Double(bytes[index + 3]) / 255.0

            return pixelAlpha >= minimumAlpha
                && abs(pixelRed - red) <= tolerance
                && abs(pixelGreen - green) <= tolerance
                && abs(pixelBlue - blue) <= tolerance
        }
    }

    func averageOpaqueLuminance(minimumAlpha: UInt8 = 200) -> Double? {
        var luminanceSum = 0.0
        var pixelCount = 0

        for index in stride(from: 0, to: bytes.count - 3, by: 4) {
            guard bytes[index + 3] >= minimumAlpha else { continue }
            let red = Double(bytes[index]) / 255.0
            let green = Double(bytes[index + 1]) / 255.0
            let blue = Double(bytes[index + 2]) / 255.0
            luminanceSum += 0.2126 * red + 0.7152 * green + 0.0722 * blue
            pixelCount += 1
        }

        guard pixelCount > 0 else { return nil }
        return luminanceSum / Double(pixelCount)
    }

    private func pixelPoint(
        forSVGPoint point: CGPoint,
        size: CGFloat,
        scale: CGFloat
    ) -> (x: Int, y: Int)? {
        // PixelBuffer's normalized rows are top-down, so the renderer's
        // flipped SVG y-down coordinate maps directly to raster y.
        let pixelsPerSVGUnit = pixelsPerSVGUnit(size: size, scale: scale)
        let x = Int((point.x * pixelsPerSVGUnit).rounded(.down))
        let y = Int((point.y * pixelsPerSVGUnit).rounded(.down))

        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return (x, y)
    }

    private func pixelsPerSVGUnit(size: CGFloat, scale: CGFloat) -> CGFloat {
        size * scale / StatusIconGeometry.canvas.width
    }

    private func alphaAt(x: Int, y: Int) -> UInt8 {
        bytes[(y * width + x) * 4 + 3]
    }
}
