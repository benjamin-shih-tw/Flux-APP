import Foundation
import SwiftData

@Model
final class UserSettings {
    var baseGoalML: Int
    var currentStreak: Int
    var longestStreak: Int
    var isRoastModeEnabled: Bool
    var mascotHP: Double // 0.0 to 100.0
    var streakFreezeTokens: Int
    
    init(baseGoalML: Int = 2000, currentStreak: Int = 0, longestStreak: Int = 0, isRoastModeEnabled: Bool = false, mascotHP: Double = 100.0, streakFreezeTokens: Int = 0) {
        self.baseGoalML = baseGoalML
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.isRoastModeEnabled = isRoastModeEnabled
        self.mascotHP = mascotHP
        self.streakFreezeTokens = streakFreezeTokens
    }
}
