import Foundation
import Vision
import UIKit
import CoreImage

struct BottleProfileExtractionResult {
    let rawProfile: [CGPoint]
    let overlayImage: UIImage
    let appearance: BottleAppearance
    let detectedCapacityML: Int?
}

private struct ExtractedBottleProfile {
    let rawProfile: [CGPoint]
    let mask: CGImage?
    let overlayOutline: [CGPoint]
}

struct BottleMaskSilhouette {
    let rawProfile: [CGPoint]
    let normalizedOutline: [CGPoint]
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
        let overlay = drawContourOverlay(on: normalizedImage, normalizedOutline: extracted.overlayOutline)
        let appearance = extracted.mask.map {
            BottleAppearanceExtractor.representativeColor(from: normalizedImage, mask: $0)
        } ?? .fallback
        return BottleProfileExtractionResult(
            rawProfile: extracted.rawProfile,
            overlayImage: overlay,
            appearance: appearance,
            detectedCapacityML: detectCapacityLabel(in: cgImage)
        )
    }

    static func capacityML(fromRecognizedText text: String) -> Int? {
        let normalized = text.uppercased().replacingOccurrences(of: ",", with: ".")
        let patterns: [(String, Double)] = [
            (#"\b([0-9]{2,4})\s*ML\b"#, 1),
            (#"\b([0-9]+(?:\.[0-9]+)?)\s*L\b"#, 1000)
        ]

        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized)
                  ),
                  let valueRange = Range(match.range(at: 1), in: normalized),
                  let value = Double(normalized[valueRange]) else { continue }
            let millilitres = Int((value * multiplier).rounded())
            if (100...5000).contains(millilitres) { return millilitres }
        }
        return nil
    }

    private static func detectCapacityLabel(in cgImage: CGImage) -> Int? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }

        return request.results?
            .compactMap { $0.topCandidates(1).first }
            .sorted { $0.confidence > $1.confidence }
            .compactMap { capacityML(fromRecognizedText: $0.string) }
            .first
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
        let silhouette = try extractSilhouette(from: maskBuffer)
        return ExtractedBottleProfile(
            rawProfile: silhouette.rawProfile,
            mask: maskImage,
            overlayOutline: silhouette.normalizedOutline
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
            rawProfile: extractRightHalfProfile(
                from: points,
                imageWidthToHeight: CGFloat(cgImage.width) / CGFloat(cgImage.height)
            ),
            mask: nil,
            overlayOutline: points.map { CGPoint(x: $0.x, y: 1 - $0.y) }
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
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1
        var foreground = 0
        var centreForeground = 0

        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                guard maskValue(in: mask, x: x, y: y) > 0.5 else { continue }
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

    static func extractSilhouette(from maskBuffer: CVPixelBuffer) throws -> BottleMaskSilhouette {
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(maskBuffer)
        let height = CVPixelBufferGetHeight(maskBuffer)
        var profile: [CGPoint] = []
        var leftOutline: [CGPoint] = []
        var rightOutline: [CGPoint] = []

        for y in 0..<height {
            var minX = width
            var maxX = -1
            for x in 0..<width {
                if maskValue(in: maskBuffer, x: x, y: y) > 0.5 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
            if maxX >= minX {
                let radius = CGFloat(maxX - minX) / 2.0 / CGFloat(height)
                let normY = 1.0 - CGFloat(y) / CGFloat(height) // 0 = bottle bottom
                profile.append(CGPoint(x: max(0.0001, radius), y: normY))
                let overlayY = CGFloat(y) / CGFloat(height)
                leftOutline.append(CGPoint(x: CGFloat(minX) / CGFloat(width), y: overlayY))
                rightOutline.append(CGPoint(x: CGFloat(maxX) / CGFloat(width), y: overlayY))
            }
        }

        guard profile.count >= 10 else { throw ExtractionError.noBottleShape }
        profile.sort { $0.y < $1.y }
        return BottleMaskSilhouette(
            rawProfile: downsampleAndSmooth(profile),
            normalizedOutline: downsampleOutline(leftOutline) + downsampleOutline(rightOutline).reversed()
        )
    }

    private static func maskValue(in buffer: CVPixelBuffer, x: Int, y: Int) -> Float {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8:
            return Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255
        case kCVPixelFormatType_OneComponent16Half:
            return Float(row.load(fromByteOffset: x * MemoryLayout<Float16>.stride, as: Float16.self))
        case kCVPixelFormatType_OneComponent32Float:
            return row.load(fromByteOffset: x * MemoryLayout<Float>.stride, as: Float.self)
        default:
            return 0
        }
    }

    private static func extractRightHalfProfile(
        from points: [CGPoint],
        imageWidthToHeight: CGFloat
    ) -> [CGPoint] {
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
            let radiusInImageHeight = (point.x - centerX) * imageWidthToHeight
            outerRadiusByRow[row] = max(outerRadiusByRow[row] ?? 0, radiusInImageHeight)
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
        let filtered = medianFiltered(smoothed, radius: 2)
        guard filtered.count > targetPoints else { return filtered }

        let step = Double(filtered.count - 1) / Double(targetPoints - 1)
        var sampled: [CGPoint] = []
        for i in 0..<targetPoints {
            let index = min(Int((Double(i) * step).rounded()), filtered.count - 1)
            sampled.append(filtered[index])
        }
        return sampled
    }

    private static func medianFiltered(_ profile: [CGPoint], radius: Int) -> [CGPoint] {
        guard profile.count >= radius * 2 + 1 else { return profile }
        return profile.indices.map { index in
            let lower = max(profile.startIndex, index - radius)
            let upper = min(profile.index(before: profile.endIndex), index + radius)
            let radii = profile[lower...upper].map(\.x).sorted()
            return CGPoint(x: radii[radii.count / 2], y: profile[index].y)
        }
    }

    private static func downsampleOutline(_ points: [CGPoint]) -> [CGPoint] {
        let targetPoints = 100
        guard points.count > targetPoints else { return points }
        let step = Double(points.count - 1) / Double(targetPoints - 1)
        return (0..<targetPoints).map { index in
            points[min(Int((Double(index) * step).rounded()), points.count - 1)]
        }
    }

    // MARK: - Overlay Drawing

    static func drawContourOverlay(on image: UIImage, normalizedOutline: [CGPoint]) -> UIImage {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: size))

        guard let ctx = UIGraphicsGetCurrentContext(), !normalizedOutline.isEmpty else {
            UIGraphicsEndImageContext()
            return image
        }

        ctx.setStrokeColor(UIColor.systemGreen.cgColor)
        ctx.setLineWidth(3)
        let points = normalizedOutline.map {
            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
        }
        ctx.move(to: points[0])
        for point in points.dropFirst() {
            ctx.addLine(to: point)
        }
        ctx.closePath()
        ctx.strokePath()

        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? size.width
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? size.height
        let centerX = (minX + maxX) / 2
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.move(to: CGPoint(x: centerX, y: minY))
        ctx.addLine(to: CGPoint(x: centerX, y: maxY))
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
