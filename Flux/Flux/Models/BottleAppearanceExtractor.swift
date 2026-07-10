import UIKit
import CoreImage

struct BottleAppearance {
    let red: Double
    let green: Double
    let blue: Double

    static let fallback = BottleAppearance(red: 0.35, green: 0.65, blue: 0.95)
}

enum BottleAppearanceExtractor {
    /// Samples only the interior of the selected bottle mask, never the whole centre rectangle.
    static func representativeColor(from image: UIImage, mask: CGImage) -> BottleAppearance {
        guard let imageCG = image.cgImage else { return .fallback }
        let width = 240
        let height = max(1, Int(CGFloat(width) * image.size.height / max(image.size.width, 1)))
        guard let imagePixels = rasterPixels(for: imageCG, width: width, height: height),
              let maskPixels = rasterPixels(for: mask, width: width, height: height) else {
            return .fallback
        }

        var reds: [UInt8] = []
        var greens: [UInt8] = []
        var blues: [UInt8] = []
        reds.reserveCapacity(width * height / 4)
        greens.reserveCapacity(width * height / 4)
        blues.reserveCapacity(width * height / 4)

        // Ignore mask edges, which tend to contain background, refraction and bright highlights.
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = (y * width + x) * 4
                guard maskPixels[index] > 128,
                      maskPixels[index - 4] > 128,
                      maskPixels[index + 4] > 128,
                      maskPixels[index - width * 4] > 128,
                      maskPixels[index + width * 4] > 128 else { continue }

                reds.append(imagePixels[index])
                greens.append(imagePixels[index + 1])
                blues.append(imagePixels[index + 2])
            }
        }

        guard !reds.isEmpty else { return .fallback }
        return BottleAppearance(
            red: Double(median(reds)) / 255.0,
            green: Double(median(greens)) / 255.0,
            blue: Double(median(blues)) / 255.0
        )
    }

    static func average(_ appearances: [BottleAppearance]) -> BottleAppearance {
        guard !appearances.isEmpty else { return .fallback }
        return BottleAppearance(
            red: appearances.map(\.red).reduce(0, +) / Double(appearances.count),
            green: appearances.map(\.green).reduce(0, +) / Double(appearances.count),
            blue: appearances.map(\.blue).reduce(0, +) / Double(appearances.count)
        )
    }

    private static func rasterPixels(for image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func median(_ values: [UInt8]) -> UInt8 {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
