import CoreGraphics
import Foundation

struct ImageSimilaritySignature: Sendable, Codable, Equatable {
    let differenceHash: UInt64
    let averageHash: UInt64
    let aspectRatio: Double
    let red: Double
    let green: Double
    let blue: Double

    var stableID: String {
        [
            String(differenceHash, radix: 16),
            String(averageHash, radix: 16),
            String(Int((aspectRatio * 32).rounded())),
        ].joined(separator: "-")
    }
}


enum ImageSimilarity {
    /// These thresholds produce review candidates, never verified duplicates.
    /// Using two visual hashes plus colour and aspect ratio avoids both the
    /// exact-bucket misses and the false matches of a single perceptual hash.
    static func score(
        _ lhs: ImageSimilaritySignature,
        _ rhs: ImageSimilaritySignature
    ) -> Double? {
        let aspectDifference = abs(lhs.aspectRatio - rhs.aspectRatio)
            / max(lhs.aspectRatio, rhs.aspectRatio)
        guard aspectDifference <= 0.12 else { return nil }
        let differenceDistance = (lhs.differenceHash ^ rhs.differenceHash).nonzeroBitCount
        let averageDistance = (lhs.averageHash ^ rhs.averageHash).nonzeroBitCount
        guard differenceDistance <= 10, averageDistance <= 10 else { return nil }
        let redDistance = lhs.red - rhs.red
        let greenDistance = lhs.green - rhs.green
        let blueDistance = lhs.blue - rhs.blue
        let colorDistance = sqrt(
            redDistance * redDistance + greenDistance * greenDistance + blueDistance * blueDistance
        ) / sqrt(3)
        guard colorDistance <= 0.28 else { return nil }
        let score = 1 - (
            0.45 * Double(differenceDistance) / 64
                + 0.35 * Double(averageDistance) / 64
                + 0.20 * colorDistance
        )
        return score >= 0.84 ? score : nil
    }

    static func signature(
        from image: CGImage
    ) -> ImageSimilaritySignature? {
        let width = 9
        let height = 8
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * bytesPerPixel,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var differenceHash: UInt64 = 0
        var luminances = [Int](repeating: 0, count: 64)
        var luminanceTotal = 0
        var redTotal = 0
        var greenTotal = 0
        var blueTotal = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                redTotal += Int(pixels[offset])
                greenTotal += Int(pixels[offset + 1])
                blueTotal += Int(pixels[offset + 2])
                guard x < width - 1 else { continue }
                let nextOffset = offset + bytesPerPixel
                let currentLuma = 299 * Int(pixels[offset])
                    + 587 * Int(pixels[offset + 1])
                    + 114 * Int(pixels[offset + 2])
                luminances[y * (width - 1) + x] = currentLuma
                luminanceTotal += currentLuma
                let nextLuma = 299 * Int(pixels[nextOffset])
                    + 587 * Int(pixels[nextOffset + 1])
                    + 114 * Int(pixels[nextOffset + 2])
                if currentLuma > nextLuma {
                    differenceHash |= UInt64(1) << UInt64(y * (width - 1) + x)
                }
            }
        }

        let averageLuminance = luminanceTotal / luminances.count
        var averageHash: UInt64 = 0
        for (index, luminance) in luminances.enumerated() where luminance >= averageLuminance {
            averageHash |= UInt64(1) << UInt64(index)
        }
        let pixelCount = width * height
        return ImageSimilaritySignature(
            differenceHash: differenceHash,
            averageHash: averageHash,
            aspectRatio: Double(image.width) / Double(image.height),
            red: Double(redTotal) / Double(pixelCount * 255),
            green: Double(greenTotal) / Double(pixelCount * 255),
            blue: Double(blueTotal) / Double(pixelCount * 255)
        )
    }

}
