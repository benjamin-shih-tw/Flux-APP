import SwiftUI
import SwiftData

@main
struct FluxApp: App {
    @AppStorage("flux_onboarding_completed") private var onboardingCompleted = false

    private let sharedModelContainer: ModelContainer

    @State private var healthManager: HealthKitManager
    @State private var weatherManager: WeatherKitManager
    @State private var dynamicGoalEngine: DynamicGoalEngine
    @State private var notificationManager: NotificationManager
    @State private var bottleAlignmentManager = BottleAlignmentManager()
    @State private var waterAPIManager = WaterAPIManager()
    @State private var watchConnectivityManager: WatchConnectivityManager

    init() {
        SourceHanFont.register()

        let container: ModelContainer
        do {
            container = try ModelContainer(for: WaterRecord.self, UserSettings.self, BottleProfile.self)
        } catch {
            fatalError("Could not initialize Flux ModelContainer: \(error)")
        }
        sharedModelContainer = container

        let health = HealthKitManager()
        let weather = WeatherKitManager()
        let goalEngine = DynamicGoalEngine()
        let notifications = NotificationManager()
        let watch = WatchConnectivityManager()
        watch.configure(
            modelContainer: container,
            healthManager: health,
            dynamicGoalEngine: goalEngine,
            weatherManager: weather,
            notificationManager: notifications
        )

        _healthManager = State(initialValue: health)
        _weatherManager = State(initialValue: weather)
        _dynamicGoalEngine = State(initialValue: goalEngine)
        _notificationManager = State(initialValue: notifications)
        _watchConnectivityManager = State(initialValue: watch)
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(\.font, .fluxFont(.body))
                .environment(healthManager)
                .environment(weatherManager)
                .environment(dynamicGoalEngine)
                .environment(notificationManager)
                .environment(bottleAlignmentManager)
                .environment(waterAPIManager)
                .environment(watchConnectivityManager)
                .fullScreenCover(
                    isPresented: Binding(
                        get: { !onboardingCompleted },
                        set: { _ in }
                    )
                ) {
                    OnboardingView {
                        onboardingCompleted = true
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
