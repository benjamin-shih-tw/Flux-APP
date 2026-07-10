import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WaterAPIManager.self) private var apiManager
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
            @Bindable var bindableAPI = apiManager

            Form {
                // MARK: Server Configuration
                Section(header: Text("Backend Server")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mac IP Address")
                            .font(.caption)
                            .foregroundColor(.gray)
                        TextField("e.g. http://10.0.0.9:8000", text: $bindableAPI.serverBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    Text("Find your Mac IP: System Settings → Wi-Fi → Details → IP Address")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                // MARK: Persona
                Section(header: Text("Persona (Push Notifications)")) {
                    Toggle(isOn: $bindableSettings.isRoastModeEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Roast Mode")
                                .font(.headline)
                            Text(bindableSettings.isRoastModeEnabled
                                 ? "Sarcastic & passive-aggressive 😈"
                                 : "Friendly & encouraging 🌱")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .tint(.blue)
                    .onChange(of: bindableSettings.isRoastModeEnabled) { _, _ in
                        Task { await notificationManager.requestAuthorization() }
                    }
                }

                // MARK: Smart Adjustments
                Section(header: Text("Smart Adjustments")) {
                    Toggle("Sync with Apple Health", isOn: $syncHealthKit)
                        .tint(.blue)
                        .onChange(of: syncHealthKit) { _, newValue in
                            if newValue { Task { await healthManager.requestAuthorization() } }
                        }
                    Toggle("Sync with WeatherKit", isOn: $syncWeatherKit)
                        .tint(.blue)
                }

                // MARK: Base Goal
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

                // MARK: About
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0 (MVP)")
                            .foregroundColor(.gray)
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
