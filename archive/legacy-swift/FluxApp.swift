import SwiftUI
import SwiftData

@main
struct FluxApp: App {
    // Initialize StateObjects / Observables for the lifecycle of the app
    @State private var healthManager = HealthKitManager()
    @State private var weatherManager = WeatherKitManager()
    @State private var dynamicGoalEngine = DynamicGoalEngine()
    @State private var notificationManager = NotificationManager()
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(healthManager)
                .environment(weatherManager)
                .environment(dynamicGoalEngine)
                .environment(notificationManager)
        }
        // SwiftData configuration
        // Bug Prevention: Setup a proper model container. In real production, we'd add migration plans here.
        .modelContainer(for: [WaterRecord.self, UserSettings.self])
    }
}
