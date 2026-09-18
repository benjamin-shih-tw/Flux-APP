import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [UserSettings]
    @Environment(HealthKitManager.self) private var healthManager
    @Environment(NotificationManager.self) private var notificationManager
    
    private var currentSettings: UserSettings {
        if let first = settingsList.first { return first }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }
    
    @State private var syncHealthKit = false
    @State private var syncWeatherKit = true
    
    var body: some View {
        NavigationStack {
            @Bindable var bindableSettings = currentSettings
            
            Form {
                Section(header: Text("Persona (Push Notifications)")) {
                    Toggle(isOn: $bindableSettings.isRoastModeEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Roast Mode")
                                .font(.headline)
                            Text(bindableSettings.isRoastModeEnabled ? "Sarcastic & passive-aggressive" : "Friendly & encouraging")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .tint(.blue)
                    .onChange(of: bindableSettings.isRoastModeEnabled) { _, _ in
                        Task {
                            await notificationManager.requestAuthorization()
                        }
                    }
                }
                
                Section(header: Text("Smart Adjustments")) {
                    Toggle("Sync with Apple Health", isOn: $syncHealthKit)
                        .tint(.blue)
                        .onChange(of: syncHealthKit) { _, newValue in
                            if newValue {
                                Task {
                                    await healthManager.requestAuthorization()
                                }
                            }
                        }
                        
                    Toggle("Sync with WeatherKit", isOn: $syncWeatherKit)
                        .tint(.blue)
                }
                
                Section(header: Text("Base Goal")) {
                    VStack {
                        HStack {
                            Text("Daily Goal")
                            Spacer()
                            Text("\(bindableSettings.baseGoalML) ml")
                                .bold()
                                .foregroundColor(.blue)
                        }
                        Slider(value: Binding(
                            get: { Double(bindableSettings.baseGoalML) },
                            set: { bindableSettings.baseGoalML = Int($0) }
                        ), in: 1500...4000, step: 100)
                            .tint(.blue)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                syncHealthKit = healthManager.isAuthorized
            }
        }
    }
}
