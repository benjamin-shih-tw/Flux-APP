import Foundation
import WidgetKit

enum HydrationWidgetStore {
    static let groupID = "group.benjaminshih.Flux"
    static let kind = "FluxHydrationWidget"

    static func update(totalML: Int, goalML: Int) {
        guard let defaults = UserDefaults(suiteName: groupID) else { return }
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let previous = defaults.double(forKey: "day")
        let oldTotal = defaults.integer(forKey: "total_ml")
        let oldGoal = defaults.integer(forKey: "goal_ml")
        guard previous != day || oldTotal != totalML || oldGoal != goalML else { return }
        defaults.set(day, forKey: "day")
        defaults.set(totalML, forKey: "total_ml")
        defaults.set(goalML, forKey: "goal_ml")
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
