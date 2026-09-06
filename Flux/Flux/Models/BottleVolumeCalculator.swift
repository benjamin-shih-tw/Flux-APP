import Foundation
import CoreGraphics

/// Integrates bottle profile geometry: V = ∫ π·r(h)² dh
enum BottleVolumeCalculator {

    struct CapacityEstimate {
        let lowerBoundML: Int
        let upperBoundML: Int
        let suggestedCapacitiesML: [Int]
        let detectedLabelCapacityML: Int?
    }

    struct CapacityFittedProfile {
        let physical: [(height: Double, radius: Double)]
        let heightCM: Double
        let openingDiameterCM: Double
        let computedVolumeML: Double
        let qualityScore: Double
    }

    /// Fits a photographed side silhouette to the capacity printed on the bottle.
    /// Raw x and y values must use the same image-height coordinate scale.
    static func fitProfileToCapacity(
        rawPoints: [CGPoint],
        capacityML: Double
    ) -> CapacityFittedProfile? {
        guard rawPoints.count >= 10, capacityML > 0 else { return nil }

        let sorted = rawPoints.sorted { $0.y < $1.y }
        guard let minY = sorted.first?.y,
              let maxY = sorted.last?.y else { return nil }
        let heightSpan = Double(maxY - minY)
        guard heightSpan > 0.05 else { return nil }

        let normalized = sorted.map { point in
            (
                height: Double(point.y - minY) / heightSpan,
                radius: max(0.0001, Double(point.x) / heightSpan)
            )
        }
        let normalizedVolume = totalVolumeML(profile: normalized)
        guard normalizedVolume.isFinite, normalizedVolume > 0 else { return nil }

        // Volume scales cubically. This single scale preserves the photographed
        // height-to-width ratio while matching the known bottle capacity exactly.
        let scaleCM = pow(capacityML / normalizedVolume, 1.0 / 3.0)
        let physical = normalized.map {
            (height: $0.height * scaleCM, radius: $0.radius * scaleCM)
        }
        let computedVolume = totalVolumeML(profile: physical)

        let topStart = 0.88
        let openingSamples = physical
            .filter { $0.height >= scaleCM * topStart }
            .map(\.radius)
            .sorted()
        let openingRadius = openingSamples.isEmpty
            ? (physical.last?.radius ?? 0)
            : openingSamples[openingSamples.count / 2]

        return CapacityFittedProfile(
            physical: physical,
            heightCM: scaleCM,
            openingDiameterCM: max(0.1, openingRadius * 2.0),
            computedVolumeML: computedVolume,
            qualityScore: profileQualityScore(
                normalized,
                frameHeightSpan: heightSpan,
                minimumFrameY: Double(minY),
                maximumFrameY: Double(maxY)
            )
        )
    }

    /// Converts a photographed silhouette to centimetres using an independently measured height.
    /// Capacity is intentionally not used as a scale because it cannot determine bottle dimensions.
    static func fitProfileToMeasuredHeight(
        rawPoints: [CGPoint],
        heightCM: Double
    ) -> CapacityFittedProfile? {
        guard rawPoints.count >= 10, heightCM > 0 else { return nil }

        let sorted = rawPoints.sorted { $0.y < $1.y }
        guard let minY = sorted.first?.y,
              let maxY = sorted.last?.y else { return nil }
        let heightSpan = Double(maxY - minY)
        guard heightSpan > 0.05 else { return nil }

        let normalized = sorted.map { point in
            (
                height: Double(point.y - minY) / heightSpan,
                radius: max(0.0001, Double(point.x) / heightSpan)
            )
        }
        let physical = normalized.map {
            (height: $0.height * heightCM, radius: $0.radius * heightCM)
        }
        let openingSamples = physical
            .filter { $0.height >= heightCM * 0.88 }
            .map(\.radius)
            .sorted()
        let openingRadius = openingSamples.isEmpty
            ? (physical.last?.radius ?? 0)
            : openingSamples[openingSamples.count / 2]

        return CapacityFittedProfile(
            physical: physical,
            heightCM: heightCM,
            openingDiameterCM: max(0.1, openingRadius * 2),
            computedVolumeML: totalVolumeML(profile: physical),
            qualityScore: profileQualityScore(
                normalized,
                frameHeightSpan: heightSpan,
                minimumFrameY: Double(minY),
                maximumFrameY: Double(maxY)
            )
        )
    }

    static func estimateCapacity(
        geometricVolumeML: Double,
        qualityScore: Double,
        detectedLabelCapacityML: Int?
    ) -> CapacityEstimate? {
        guard geometricVolumeML.isFinite, geometricVolumeML >= 100 else { return nil }

        // A small endpoint error in AR height is cubed when converted to volume.
        // Keep the estimate honest and rank common bottle sizes inside that uncertainty band.
        let clampedQuality = max(0, min(1, qualityScore))
        let relativeUncertainty = 0.30 + (1 - clampedQuality) * 0.15
        let lower = max(100, geometricVolumeML * (1 - relativeUncertainty))
        let upper = min(5000, geometricVolumeML * (1 + relativeUncertainty))
        let commonCapacities = [250, 330, 350, 400, 450, 500, 600, 650, 750, 800, 1000, 1200, 1500, 2000, 2500, 3000]

        var suggestions = commonCapacities
            .filter { Double($0) >= lower && Double($0) <= upper }
            .sorted {
                abs(log(Double($0) / geometricVolumeML)) < abs(log(Double($1) / geometricVolumeML))
            }
        if let detectedLabelCapacityML {
            suggestions.removeAll { $0 == detectedLabelCapacityML }
            suggestions.insert(detectedLabelCapacityML, at: 0)
        }

        return CapacityEstimate(
            lowerBoundML: Int((lower / 50).rounded(.down) * 50),
            upperBoundML: Int((upper / 50).rounded(.up) * 50),
            suggestedCapacitiesML: Array(suggestions.prefix(3)),
            detectedLabelCapacityML: detectedLabelCapacityML
        )
    }

    /// Calibrate raw Vision profile (normalized y, relative radius) to physical cm.
    static func calibrateProfile(
        rawPoints: [CGPoint],
        heightCM: Double,
        openingRadiusCM: Double
    ) -> [(height: Double, radius: Double)] {
        guard !rawPoints.isEmpty, heightCM > 0, openingRadiusCM > 0 else { return [] }

        let ys = rawPoints.map(\.y)
        let xs = rawPoints.map(\.x)
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 1
        let heightSpan = maxY - minY
        guard heightSpan > 0 else { return [] }

        // The user enters the bottle opening diameter, so calibrate against the upper neck/opening.
        // Mapping the widest body point to this value shrinks most bottles and corrupts volume.
        let openingThreshold = minY + heightSpan * 0.90
        let openingSamples = rawPoints
            .filter { Double($0.y) >= Double(openingThreshold) }
            .map { Double($0.x) }
            .sorted()
        let openingRelativeRadius: Double
        if openingSamples.isEmpty {
            openingRelativeRadius = Double(xs.max() ?? 0)
        } else {
            openingRelativeRadius = openingSamples[openingSamples.count / 2]
        }
        guard openingRelativeRadius > 0 else { return [] }

        let scale = openingRadiusCM / openingRelativeRadius

        return rawPoints.map { pt in
            let h = ((Double(pt.y) - Double(minY)) / Double(heightSpan)) * heightCM
            let r = Double(pt.x) * scale
            return (height: h, radius: max(0.001, r))
        }.sorted { $0.height < $1.height }
    }

    /// Volume in ml (cm³) below a given water height.
    static func volumeBelowHeight(
        profile: [(height: Double, radius: Double)],
        waterHeightCM: Double
    ) -> Double {
        guard profile.count >= 2, waterHeightCM > 0 else { return 0 }

        let sorted = profile.sorted { $0.height < $1.height }
        let maxH = sorted.last!.height
        let clampedH = min(waterHeightCM, maxH)

        var volume = 0.0
        for i in 0..<(sorted.count - 1) {
            let h0 = sorted[i].height
            let h1 = sorted[i + 1].height
            if h1 > clampedH {
                let r0 = sorted[i].radius
                let r1 = interpolateRadius(at: clampedH, profile: sorted)
                let dh = clampedH - h0
                volume += trapezoidSlice(r0: r0, r1: r1, dh: dh)
                return volume
            }
            let dh = h1 - h0
            volume += trapezoidSlice(r0: sorted[i].radius, r1: sorted[i + 1].radius, dh: dh)
        }
        return volume
    }

    /// Total bottle volume from profile.
    static func totalVolumeML(profile: [(height: Double, radius: Double)]) -> Double {
        guard let maxH = profile.map(\.height).max() else { return 0 }
        return volumeBelowHeight(profile: profile, waterHeightCM: maxH)
    }

    private static func profileQualityScore(
        _ profile: [(height: Double, radius: Double)],
        frameHeightSpan: Double,
        minimumFrameY: Double,
        maximumFrameY: Double
    ) -> Double {
        guard profile.count >= 10 else { return 0 }

        let positiveRadii = profile.map(\.radius).filter { $0 > 0 }
        guard let maxRadius = positiveRadii.max(), maxRadius > 0 else { return 0 }

        let diameterToHeight = maxRadius * 2.0
        let aspectScore: Double
        if diameterToHeight >= 0.12 && diameterToHeight <= 0.85 {
            aspectScore = 1
        } else {
            let distance = diameterToHeight < 0.12
                ? (0.12 - diameterToHeight) / 0.12
                : (diameterToHeight - 0.85) / 0.85
            aspectScore = max(0, 1 - distance)
        }

        let radii = profile.map(\.radius)
        var roughness = 0.0
        if radii.count >= 3 {
            for index in 1..<(radii.count - 1) {
                roughness += abs(radii[index - 1] - 2 * radii[index] + radii[index + 1])
            }
            roughness /= Double(radii.count - 2) * maxRadius
        }
        let smoothnessScore = max(0, min(1, 1 - roughness * 8))
        let sampleScore = min(1, Double(profile.count) / 40.0)

        let geometryScore = aspectScore * 0.45 + smoothnessScore * 0.35 + sampleScore * 0.20
        let coverageScore = max(0, min(1, frameHeightSpan / 0.50))
        let marginScore = minimumFrameY > 0.01 && maximumFrameY < 0.99 ? 1.0 : 0.55

        return max(0, min(1, geometryScore * coverageScore * marginScore))
    }

    /// Find water height where profile radius matches the given water surface radius.
    static func heightFromWaterRadius(
        profile: [(height: Double, radius: Double)],
        waterRadiusCM: Double
    ) -> Double? {
        guard profile.count >= 2 else { return nil }

        let sorted = profile.sorted { $0.height < $1.height }

        // Search for crossing where r(h) ≈ waterRadiusCM
        for i in 0..<(sorted.count - 1) {
            let r0 = sorted[i].radius
            let r1 = sorted[i + 1].radius
            let h0 = sorted[i].height
            let h1 = sorted[i + 1].height

            let minR = min(r0, r1)
            let maxR = max(r0, r1)
            if waterRadiusCM >= minR - 0.05 && waterRadiusCM <= maxR + 0.05 {
                if abs(r1 - r0) < 0.001 {
                    return (h0 + h1) / 2.0
                }
                let t = (waterRadiusCM - r0) / (r1 - r0)
                return h0 + t * (h1 - h0)
            }
        }

        // Fallback: closest match
        var bestH: Double?
        var bestDiff = Double.infinity
        for pt in sorted {
            let diff = abs(pt.radius - waterRadiusCM)
            if diff < bestDiff {
                bestDiff = diff
                bestH = pt.height
            }
        }
        return bestH
    }

    // MARK: - Private

    private static func trapezoidSlice(r0: Double, r1: Double, dh: Double) -> Double {
        let a0 = Double.pi * r0 * r0
        let a1 = Double.pi * r1 * r1
        return (a0 + a1) / 2.0 * dh
    }

    private static func interpolateRadius(
        at height: Double,
        profile: [(height: Double, radius: Double)]
    ) -> Double {
        for i in 0..<(profile.count - 1) {
            let h0 = profile[i].height
            let h1 = profile[i + 1].height
            if height >= h0 && height <= h1 {
                let t = (height - h0) / (h1 - h0)
                return profile[i].radius + t * (profile[i + 1].radius - profile[i].radius)
            }
        }
        return profile.last?.radius ?? 0
    }
}
