import Foundation

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
}
