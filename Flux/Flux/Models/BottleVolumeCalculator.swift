import Foundation
import CoreGraphics

/// Integrates bottle profile geometry: V = ∫ π·r(h)² dh
enum BottleVolumeCalculator {

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
