import Foundation
import UIKit

/// Result from a top-down bottle scan via the Python backend.
struct WaterScanResult {
    let remainingML: Double
    let consumedML: Double?
    let waterDepthCM: Double?
    let waterHeightCM: Double?
    let confidence: Double
    let methodUsed: String
    let outerRadiusPx: Double?
    let debugImageBase64: String?
    let message: String
    let echoSNRDB: Double?
    let resonanceSNRDB: Double?
    let resonanceFrequencyHz: Double?
    let acceptedAcousticRepeats: Int?
}

/// One ranked candidate water surface circle returned by the backend.
struct WaterSurfaceCandidate: Identifiable, Codable, Equatable {
    let id: Int
    let centerX: Double
    let centerY: Double
    let radiusPx: Double
    let radiusRatio: Double
    let remainingVolumeML: Double?
    let consumedVolumeML: Double?
    let waterHeightCM: Double?
    let waterDepthCM: Double?
    let score: Double
    let coverage: Double
    let likelyBase: Bool
    let recommended: Bool
    let peakLensPosition: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case centerX = "center_x"
        case centerY = "center_y"
        case radiusPx = "radius_px"
        case radiusRatio = "radius_ratio"
        case remainingVolumeML = "remaining_volume_ml"
        case consumedVolumeML = "consumed_volume_ml"
        case waterHeightCM = "water_height_cm"
        case waterDepthCM = "water_depth_cm"
        case score
        case coverage
        case likelyBase = "likely_base"
        case recommended
        case peakLensPosition = "peak_lens_position"
    }
}

/// Interactive review bundle allowing the user to verify the model's predicted
/// water surface circle or immediately switch/adjust to the true water edge.
struct WaterScanReview {
    let status: String
    let message: String
    let reviewImage: UIImage
    let rawImageWidth: Int
    let rawImageHeight: Int
    let outerCenterX: Double
    let outerCenterY: Double
    let outerRadiusPx: Double
    let focalLengthPx: Double
    let phoneToRimCM: Double
    let imuAlignmentScore: Double
    let reconciledHeightsCM: [Double]
    let reconciledRadiiCM: [Double]
    let candidates: [WaterSurfaceCandidate]
    let recommendedCandidateIndex: Int?
    let autoResult: WaterScanResult?
    let focusStackCount: Int
    let selectedFocusIndex: Int
    let selectedLensPosition: Double?
    let sharpnessGain: Double?
    let lastRemainingBaselineML: Double?
    let previousScanAgeSeconds: Double?
}
