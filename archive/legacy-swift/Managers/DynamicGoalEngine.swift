import Foundation
import SwiftUI

@Observable
final class DynamicGoalEngine {
    // Calculates the adjusted daily goal based on current environment and health context
    var baseGoalML: Double = 2000.0
    
    // Bug Prevention: Ensure we don't adjust goals to dangerous levels (Water Intoxication / Hyponatremia)
    let MAX_SAFE_DAILY_GOAL_ML: Double = 5000.0
    
    func calculateTodayGoal(activeEnergyKCal: Double, apparentTempCelsius: Double?) -> Int {
        var dynamicGoal = baseGoalML
        
        // 1. Weather Adjustment
        // If apparent temperature > 28°C, add 100ml per extra degree
        if let temp = apparentTempCelsius, temp > 28.0 {
            let extraHeatTemp = temp - 28.0
            dynamicGoal += (extraHeatTemp * 100.0)
        }
        
        // 2. Workout Adjustment
        // Roughly add 1ml for every 1 kcal burned from active energy (This is a simplified heuristic)
        dynamicGoal += activeEnergyKCal
        
        // Cap the goal to prevent dangerous recommendations
        if dynamicGoal > MAX_SAFE_DAILY_GOAL_ML {
            dynamicGoal = MAX_SAFE_DAILY_GOAL_ML
        }
        
        return Int(dynamicGoal)
    }
}
