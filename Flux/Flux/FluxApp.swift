import SwiftUI
import SwiftData

@main
struct FluxApp: App {
    @State private var healthManager = HealthKitManager()
    @State private var weatherManager = WeatherKitManager()
    @State private var dynamicGoalEngine = DynamicGoalEngine()
    @State private var notificationManager = NotificationManager()
    @State private var bottleAlignmentManager = BottleAlignmentManager()
    @State private var waterAPIManager = WaterAPIManager()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(healthManager)
                .environment(weatherManager)
                .environment(dynamicGoalEngine)
                .environment(notificationManager)
                .environment(bottleAlignmentManager)
                .environment(waterAPIManager)
        }
        .modelContainer(for: [WaterRecord.self, UserSettings.self, BottleProfile.self])
    }
}
