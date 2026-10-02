import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WaterAPIManager.self) private var apiManager
    @Query private var settingsList: [UserSettings]
    @Environment(HealthKitManager.self) private var healthManager
    @Environment(NotificationManager.self) private var notificationManager
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Query(sort: \WaterRecord.timestamp, order: .reverse) private var waterRecords: [WaterRecord]

    private var currentSettings: UserSettings {
        if let first = settingsList.first { return first }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }

    @State private var syncHealthKit = false
    @State private var syncWeatherKit = true
    @AppStorage("flux_reminders_enabled") private var remindersEnabled = false
    @AppStorage("flux_reminder_interval_hours") private var reminderIntervalHours = 2
    @AppStorage("flux_onboarding_completed") private var onboardingCompleted = false

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return version + " (build " + build + ")"
    }

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
                        if remindersEnabled {
                            Task { await refreshReminderSchedule() }
                        } else {
                            Task { await notificationManager.requestAuthorization() }
                        }
                    }
                }

                // MARK: Hydration Reminders
                Section(header: Text("Hydration Reminders")) {
                    Toggle("Remind me to drink", isOn: $remindersEnabled)
                        .tint(.blue)
                        .onChange(of: remindersEnabled) { _, _ in
                            Task { await refreshReminderSchedule() }
                        }

                    if remindersEnabled {
                        Picker("Remind every", selection: $reminderIntervalHours) {
                            Text("1 hour").tag(1)
                            Text("2 hours").tag(2)
                            Text("3 hours").tag(3)
                            Text("4 hours").tag(4)
                        }
                        .onChange(of: reminderIntervalHours) { _, _ in
                            Task { await refreshReminderSchedule() }
                        }

                        Text("Flux will send one optional reminder at the selected interval. You can change or disable it at any time.")
                            .font(.caption)
                            .foregroundColor(.gray)
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

                // MARK: Apple Watch
                Section(header: Text("Apple Watch")) {
                    HStack {
                        Label("Connection", systemImage: "applewatch")
                        Spacer()
                        Text(watchManager.isPaired ? (watchManager.isReachable ? "Connected" : "Paired") : "Not paired")
                            .foregroundColor(watchManager.isPaired ? .green : .secondary)
                    }

                    Button("Sync today's total") {
                        let start = Calendar.current.startOfDay(for: Date())
                        let total = waterRecords
                            .filter { $0.timestamp >= start }
                            .reduce(0) { $0 + $1.amountML }
                        watchManager.sendTodaySnapshot(
                            totalML: total,
                            goalML: max(currentSettings.baseGoalML, 1)
                        )
                    }
                    .disabled(!watchManager.isPaired)

                    Text("Install FluxWatch on your paired Apple Watch to add 100, 250, or 500 ml and sync the result back to Flux.")
                        .font(.caption)
                        .foregroundColor(.gray)
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
                        Text(appVersion)
                            .foregroundColor(.gray)
                    }

                    Button {
                        onboardingCompleted = false
                    } label: {
                        Label("Replay introduction", systemImage: "book.closed")
                    }

                    Text("Flux is an estimation tool. Always confirm an unusual result and retake the photo when the bottle is tilted, cropped, or reflective.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                syncHealthKit = healthManager.isAuthorized
            }
        }
    }

    @MainActor
    private func refreshReminderSchedule() async {
        if remindersEnabled {
            await notificationManager.requestAuthorization()
            guard notificationManager.isAuthorized else {
                remindersEnabled = false
                return
            }
            notificationManager.scheduleRepeatingReminder(
                isRoastMode: currentSettings.isRoastModeEnabled,
                intervalHours: reminderIntervalHours
            )
        } else {
            notificationManager.cancelReminders()
        }
    }
}
