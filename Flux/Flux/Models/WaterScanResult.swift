import Foundation

/// Result from a top-down bottle scan via the Python backend.
struct WaterScanResult {
    let remainingML: Double
    let consumedML: Double?
    let waterHeightCM: Double?
    let outerRadiusPx: Double?
    let debugImageBase64: String?
    let message: String
}
