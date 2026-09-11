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

    /// Tracks the last date streak logic was evaluated to avoid double-counting.
    var lastStreakCheckDate: Date?

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
        lastScanWaterHeightCM: Double = 0,
        lastStreakCheckDate: Date? = nil
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
        self.lastStreakCheckDate = lastStreakCheckDate
    }

    var bottleFillFraction: Float {
        guard lastScanBottleCapacityML > 0 else { return 0 }
        return Float(min(lastScanRemainingML / lastScanBottleCapacityML, 1.0))
    }

    // MARK: - Streak Calculation

    /// Call after each water log to update the streak.
    /// `todayIntake` should be the total intake for today (including the just-logged amount).
    /// `yesterdayIntake` is needed to evaluate whether yesterday met the goal when crossing midnight.
    func updateStreak(todayIntake: Int, yesterdayIntake: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Only run full day-boundary check once per calendar day.
        if let lastCheck = lastStreakCheckDate, cal.isDate(lastCheck, inSameDayAs: today) {
            // Same day — just check if today now meets goal for the first time.
            if todayIntake >= baseGoalML {
                // Today is on track; streak is already handled.
            }
            return
        }

        // New day detected — evaluate yesterday.
        let yesterdayMetGoal = yesterdayIntake >= baseGoalML

        if yesterdayMetGoal {
            // Yesterday was good, streak continues.
            currentStreak += 1
        } else if streakFreezeTokens > 0 && currentStreak > 0 {
            // Missed yesterday but have a freeze token — use it to save the streak.
            streakFreezeTokens -= 1
            // Streak stays the same (frozen), don't increment.
        } else {
            // Streak broken.
            currentStreak = 0
        }

        // If today already meets the goal at check time, count it.
        if todayIntake >= baseGoalML && currentStreak == 0 {
            currentStreak = 1
        }

        longestStreak = max(longestStreak, currentStreak)
        lastStreakCheckDate = today
    }
}
