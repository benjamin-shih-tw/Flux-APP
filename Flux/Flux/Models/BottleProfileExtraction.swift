import Foundation
import Vision
import UIKit
import CoreImage

struct BottleProfileExtractionResult {
    let rawProfile: [CGPoint]
    let overlayImage: UIImage
    let appearance: BottleAppearance
}

private struct ExtractedBottleProfile {
    let rawProfile: [CGPoint]
    let mask: CGImage?
}

class BottleProfileExtraction {

    static func extractRightProfile(from image: UIImage) async throws -> BottleProfileExtractionResult {
        // Camera JPEGs often carry a portrait orientation tag while their CGImage pixels remain landscape.
        // Bake the orientation before Vision and row-by-row silhouette extraction use those pixels.
        let normalizedImage = image.normalizedUpImage()
        guard let cgImage = normalizedImage.cgImage else {
            throw ExtractionError.invalidImage
        }

        let extracted = try await extractContourPoints(from: cgImage)
        let overlay = drawContourOverlay(on: normalizedImage, profile: extracted.rawProfile)
        let appearance = extracted.mask.map {
            BottleAppearanceExtractor.representativeColor(from: normalizedImage, mask: $0)
        } ?? .fallback
        return BottleProfileExtractionResult(
            rawProfile: extracted.rawProfile,
            overlayImage: overlay,
            appearance: appearance
        )
    }

    // MARK: - Contour Extraction

    private static func extractContourPoints(from cgImage: CGImage) async throws -> ExtractedBottleProfile {
        // Try foreground mask first (iOS 17+), then fall back to raw contours.
        if let masked = try? await extractViaForegroundMask(from: cgImage) {
            return masked
        }
        return try await extractViaContours(from: cgImage)
    }

    private static func extractViaForegroundMask(from cgImage: CGImage) async throws -> ExtractedBottleProfile {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first else {
            throw ExtractionError.noContours
        }

        let selectedInstance = try selectBottleInstance(from: result, handler: handler)
        let maskBuffer = try result.generateScaledMaskForImage(forInstances: selectedInstance, from: handler)
        let maskImage = maskBufferToCGImage(maskBuffer, width: cgImage.width, height: cgImage.height)
        return ExtractedBottleProfile(
            rawProfile: try extractSilhouetteProfile(from: maskImage),
            mask: maskImage
        )
    }

    private static func extractViaContours(from cgImage: CGImage) async throws -> ExtractedBottleProfile {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.5
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 1024

        try requestHandler.perform([request])

        guard let observation = request.results?.first as? VNContoursObservation else {
            throw ExtractionError.noContours
        }

        var bestPoints: [CGPoint]?
        var bestScore = -CGFloat.infinity

        for i in 0..<observation.contourCount {
            let contour = try observation.contour(at: i)
            let points = contour.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            guard points.count >= 12 else { continue }
            let minX = points.map(\.x).min() ?? 0
            let maxX = points.map(\.x).max() ?? 1
            let minY = points.map(\.y).min() ?? 0
            let maxY = points.map(\.y).max() ?? 1
            let width = maxX - minX
            let height = maxY - minY
            guard width > 0.04, height > 0.10 else { continue }

            let centreX = (minX + maxX) / 2
            let centred = max(0, 1 - abs(centreX - 0.5) * 2)
            let tallness = min(height / width, 4.0)
            let avoidsFrame: CGFloat = (minX > 0.01 && maxX < 0.99 && minY > 0.01 && maxY < 0.99) ? 1.0 : 0.0
            let score = centred * 4.0 + tallness + avoidsFrame
            if score > bestScore {
                bestScore = score
                bestPoints = points
            }
        }

        guard let points = bestPoints else {
            throw ExtractionError.noBottleShape
        }
        return ExtractedBottleProfile(
            rawProfile: extractRightHalfProfile(from: points),
            mask: nil
        )
    }

    /// Chooses one foreground instance. Using all instances lets hands or nearby objects widen the bottle.
    private static func selectBottleInstance(
        from result: VNInstanceMaskObservation,
        handler: VNImageRequestHandler
    ) throws -> IndexSet {
        var bestInstance: IndexSet?
        var bestScore = -Double.infinity

        for identifier in result.allInstances {
            let candidate = IndexSet(integer: identifier)
            let mask = try result.generateScaledMaskForImage(forInstances: candidate, from: handler)
            let score = scoreBottleMask(mask)
            if score > bestScore {
                bestScore = score
                bestInstance = candidate
            }
        }

        guard let bestInstance else { throw ExtractionError.noBottleShape }
        return bestInstance
    }

    private static func scoreBottleMask(_ mask: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return -.infinity }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1
        var foreground = 0
        var centreForeground = 0

        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let value = base.load(fromByteOffset: y * rowBytes + x, as: UInt8.self)
                guard value > 128 else { continue }
                foreground += 1
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                if abs(x - width / 2) < width / 4 && abs(y - height / 2) < height / 2 {
                    centreForeground += 1
                }
            }
        }

        guard foreground > 0, maxX >= minX, maxY >= minY else { return -.infinity }
        let boxWidth = Double(maxX - minX + 1) / Double(width)
        let boxHeight = Double(maxY - minY + 1) / Double(height)
        let centreX = Double(minX + maxX) / 2.0 / Double(width)
        let horizontalCentreScore = max(0, 1.0 - abs(centreX - 0.5) * 2.0)
        let centreCoverage = Double(centreForeground) / Double(foreground)

        // Prefer a tall object positioned in the guided centre region, without always favouring a huge foreground.
        return horizontalCentreScore * 5.0 + centreCoverage * 2.0 + boxHeight * 2.0 - boxWidth * 0.25
    }

    private static func extractSilhouetteProfile(from maskImage: CGImage) throws -> [CGPoint] {
        let width = maskImage.width
        let height = maskImage.height

        guard let data = maskImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            throw ExtractionError.noBottleShape
        }

        var profile: [CGPoint] = []
        let rowBytes = maskImage.bytesPerRow

        // A foreground-mask row gives the full left-to-right bottle width.
        // The old implementation only retained maxX, then subtracted maxX values from
        // each other. For a straight-sided bottle that produced radius = 0 at every row.
        for y in 0..<height {
            var minX = width
            var maxX = -1
            for x in 0..<width {
                if ptr[y * rowBytes + x] > 128 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
            if maxX >= minX {
                let radius = CGFloat(maxX - minX) / 2.0 / CGFloat(width)
                let normY = 1.0 - CGFloat(y) / CGFloat(height) // 0 = bottle bottom
                profile.append(CGPoint(x: max(0.0001, radius), y: normY))
            }
        }

        guard profile.count >= 10 else { throw ExtractionError.noBottleShape }
        profile.sort { $0.y < $1.y }
        return downsampleAndSmooth(profile)
    }

    private static func extractRightHalfProfile(from points: [CGPoint]) -> [CGPoint] {
        let xs = points.map(\.x)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 1
        let centerX = (minX + maxX) / 2.0

        // A contour can contain several points at the same height. Keep the outermost right edge,
        // rather than whichever point happens to appear first in the contour path.
        var outerRadiusByRow: [Int: CGFloat] = [:]
        let rows = 160
        for point in points where point.x >= centerX {
            let row = min(rows - 1, max(0, Int(point.y * CGFloat(rows - 1))))
            outerRadiusByRow[row] = max(outerRadiusByRow[row] ?? 0, point.x - centerX)
        }

        let rightProfile = outerRadiusByRow.keys.sorted().map { row in
            CGPoint(
                x: outerRadiusByRow[row] ?? 0.0001,
                y: CGFloat(row) / CGFloat(rows - 1)
            )
        }
        return downsampleAndSmooth(rightProfile)
    }

    private static func downsampleAndSmooth(_ profile: [CGPoint]) -> [CGPoint] {
        var smoothed: [CGPoint] = []
        for pt in profile {
            if let last = smoothed.last {
                if pt.y - last.y > 0.001 {
                    smoothed.append(pt)
                }
            } else {
                smoothed.append(pt)
            }
        }

        let targetPoints = 50
        guard smoothed.count > targetPoints else { return smoothed }

        let step = Double(smoothed.count) / Double(targetPoints)
        var sampled: [CGPoint] = []
        for i in 0..<targetPoints {
            let index = min(Int(Double(i) * step), smoothed.count - 1)
            sampled.append(smoothed[index])
        }
        return sampled
    }

    // MARK: - Overlay Drawing

    static func drawContourOverlay(on image: UIImage, profile: [CGPoint]) -> UIImage {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: size))

        guard let ctx = UIGraphicsGetCurrentContext(), !profile.isEmpty else {
            return image
        }

        let maxRelX = profile.map(\.x).max() ?? 1
        let centerNormX = 0.5 // approximate image center

        ctx.setStrokeColor(UIColor.systemGreen.cgColor)
        ctx.setLineWidth(3)

        // Draw mirrored full silhouette
        var leftPoints: [CGPoint] = []
        var rightPoints: [CGPoint] = []

        for pt in profile {
            let screenX = centerNormX * size.width
            let radiusPx = (pt.x / max(maxRelX, 0.001)) * size.width * 0.25
            let screenY = (1.0 - pt.y) * size.height

            rightPoints.append(CGPoint(x: screenX + radiusPx, y: screenY))
            leftPoints.append(CGPoint(x: screenX - radiusPx, y: screenY))
        }

        let allPoints = leftPoints.reversed() + rightPoints
        guard allPoints.count >= 2 else { return image }

        ctx.move(to: allPoints[0])
        for pt in allPoints.dropFirst() {
            ctx.addLine(to: pt)
        }
        ctx.closePath()
        ctx.strokePath()

        // Draw center axis
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.move(to: CGPoint(x: centerNormX * size.width, y: 0))
        ctx.addLine(to: CGPoint(x: centerNormX * size.width, y: size.height))
        ctx.strokePath()

        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    // MARK: - Helpers

    private static func maskBufferToCGImage(_ buffer: CVPixelBuffer, width: Int, height: Int) -> CGImage {
        CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height))!
    }

    enum ExtractionError: LocalizedError {
        case invalidImage
        case noContours
        case noBottleShape

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Invalid image"
            case .noContours: return "No contours found. Use a plain background."
            case .noBottleShape: return "Could not identify bottle shape."
            }
        }
    }
}

private extension UIImage {
    func normalizedUpImage() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
