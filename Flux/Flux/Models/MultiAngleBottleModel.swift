import Foundation
import CoreGraphics

/// A compact, persistent representation of one side silhouette captured at a known turn angle.
/// Points use display coordinates: x = radius, y = height.
struct MultiAngleBottleScan: Codable {
    let angleDegrees: Double
    let points: [MultiAngleBottlePoint]
}

struct MultiAngleBottlePoint: Codable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
