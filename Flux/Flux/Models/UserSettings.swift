import Foundation
import SwiftData

@Model
final class UserSettings {
    var baseGoalML: Int
    var currentStreak: Int
    var longestStreak: Int
    var isRoastModeEnabled: Bool
    var mascotHP: Double
    var streakFreezeTokens: Int

    var lastScanRemainingML: Double
    var lastScanBottleCapacityML: Double
    var lastScanTimestamp: Date?
    var lastScanWaterHeightCM: Double

    init(
        baseGoalML: Int = 2000,
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        isRoastModeEnabled: Bool = false,
        mascotHP: Double = 100.0,
        streakFreezeTokens: Int = 0,
        lastScanRemainingML: Double = 0,
        lastScanBottleCapacityML: Double = 500,
        lastScanTimestamp: Date? = nil,
        lastScanWaterHeightCM: Double = 0
    ) {
        self.baseGoalML = baseGoalML
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.isRoastModeEnabled = isRoastModeEnabled
        self.mascotHP = mascotHP
        self.streakFreezeTokens = streakFreezeTokens
        self.lastScanRemainingML = lastScanRemainingML
        self.lastScanBottleCapacityML = lastScanBottleCapacityML
        self.lastScanTimestamp = lastScanTimestamp
        self.lastScanWaterHeightCM = lastScanWaterHeightCM
    }

    var bottleFillFraction: Float {
        guard lastScanBottleCapacityML > 0 else { return 0 }
        return Float(min(lastScanRemainingML / lastScanBottleCapacityML, 1.0))
    }
}
