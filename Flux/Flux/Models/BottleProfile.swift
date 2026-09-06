import Foundation
import SwiftData

/// Stores a user's registered bottle profile.
/// Created during the AR Bottle Modeling scan, reused every time they scan this bottle.
@Model
final class BottleProfile {
    var name: String
    var totalVolumeMl: Double
    var heightCM: Double
    var diameterCM: Double
    var createdAt: Date
    var isDefault: Bool

    /// Normalized mesh points for 3D display (SceneKit units)
    var contourXs: [Double]
    var contourYs: [Double]

    /// Calibrated physical profile in cm — used by the scan backend
    var profileRadiusCM: [Double]
    var profileHeightCM: [Double]

    /// Volume computed from profile integration (∫πr²dh)
    var computedVolumeML: Double

    /// Baseline outer-rim pixel radius from first top-down calibration scan
    var calibrationOuterRadiusPx: Double

    /// Eight side silhouettes encoded as JSON. This preserves a non-rotational 3D mesh for Dashboard.
    var multiAngleScanData: Data = Data()

    /// Representative colour extracted from the guided side photos.
    var modelColorRed: Double = 0.35
    var modelColorGreen: Double = 0.65
    var modelColorBlue: Double = 0.95

    init(
        name: String = "My Bottle",
        totalVolumeMl: Double = 500,
        heightCM: Double = 20,
        diameterCM: Double = 7,
        isDefault: Bool = false,
        contourXs: [Double] = [],
        contourYs: [Double] = [],
        profileRadiusCM: [Double] = [],
        profileHeightCM: [Double] = [],
        computedVolumeML: Double = 0,
        calibrationOuterRadiusPx: Double = 0,
        multiAngleProfiles: [[CGPoint]] = [],
        appearance: BottleAppearance = .fallback
    ) {
        self.name = name
        self.totalVolumeMl = totalVolumeMl
        self.heightCM = heightCM
        self.diameterCM = diameterCM
        self.createdAt = Date()
        self.isDefault = isDefault
        self.contourXs = contourXs
        self.contourYs = contourYs
        self.profileRadiusCM = profileRadiusCM
        self.profileHeightCM = profileHeightCM
        self.computedVolumeML = computedVolumeML
        self.calibrationOuterRadiusPx = calibrationOuterRadiusPx
        let scans = multiAngleProfiles.enumerated().map { index, profile in
            MultiAngleBottleScan(
                angleDegrees: Double(index) * (360.0 / Double(max(multiAngleProfiles.count, 1))),
                points: profile.map(MultiAngleBottlePoint.init)
            )
        }
        self.multiAngleScanData = (try? JSONEncoder().encode(scans)) ?? Data()
        self.modelColorRed = appearance.red
        self.modelColorGreen = appearance.green
        self.modelColorBlue = appearance.blue
    }

    var profilePoints: [CGPoint] {
        guard contourXs.count == contourYs.count else { return [] }
        return zip(contourXs, contourYs).map { CGPoint(x: $0, y: $1) }
    }

    var openingRadiusCM: Double { diameterCM / 2.0 }

    var hasCalibratedProfile: Bool {
        profileRadiusCM.count >= 2 && profileHeightCM.count >= 2
    }

    var multiAngleProfiles: [[CGPoint]] {
        guard let scans = try? JSONDecoder().decode([MultiAngleBottleScan].self, from: multiAngleScanData) else {
            return []
        }
        return scans
            .sorted { $0.angleDegrees < $1.angleDegrees }
            .map { $0.points.map(\.cgPoint) }
    }

    var hasMultiAngleModel: Bool {
        multiAngleProfiles.count >= 3
    }

    var modelColor: (red: Double, green: Double, blue: Double) {
        (modelColorRed, modelColorGreen, modelColorBlue)
    }

    var displaySummary: String {
        "\(Int(totalVolumeMl))ml · H:\(String(format: "%.1f", heightCM))cm · Ø\(String(format: "%.1f", diameterCM))cm"
    }
}
