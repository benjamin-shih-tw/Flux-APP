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

    @AppStorage("flux_health_enabled") private var syncHealthKit = false
    @State private var syncWeatherKit = true
    @State private var showGoalEditor = false
    @State private var showAdvancedSettings = false
    @State private var showAbout = false
    @AppStorage("flux_reminders_enabled") private var remindersEnabled = false
    @AppStorage("flux_reminder_interval_hours") private var reminderIntervalHours = 2
    @AppStorage("flux_onboarding_completed") private var onboardingCompleted = false

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return version + " (build " + build + ")"
    }

    private var csvExport: String {
        let formatter = ISO8601DateFormatter()
        let rows = waterRecords
            .sorted { $0.timestamp < $1.timestamp }
            .map { "\(formatter.string(from: $0.timestamp)),\($0.amountML)" }
        return (["timestamp,amount_ml"] + rows).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            @Bindable var bindableSettings = currentSettings
            @Bindable var bindableAPI = apiManager

            Form {
                Section(header: Text("Hydration")) {
                    Button { showGoalEditor = true } label: {
                        HStack {
                            Label("Daily goal", systemImage: "drop")
                            Spacer()
                            Text("\(bindableSettings.baseGoalML.formatted()) ml")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Toggle(isOn: $remindersEnabled) {
                        Label("Hydration reminders", systemImage: "bell")
                    }
                        .tint(FluxTheme.accent)
                        .onChange(of: remindersEnabled) { _, _ in
                            Task { await refreshReminderSchedule() }
                        }

                    Toggle(isOn: $syncHealthKit) {
                        Label("Apple Health", systemImage: "heart")
                    }
                        .tint(FluxTheme.accent)
                        .onChange(of: syncHealthKit) { _, newValue in
                            if newValue {
                                UserDefaults.standard.set(Date(), forKey: "flux_health_enabled_at")
                                Task {
                                    await healthManager.requestAuthorization()
                                    if !healthManager.isAuthorized { syncHealthKit = false }
                                    else { await healthManager.syncWaterRecords(waterRecords) }
                                }
                            }
                        }

                    HStack {
                        Label("Apple Watch", systemImage: "applewatch")
                        Spacer()
                        Text(watchManager.isPaired ? (watchManager.isReachable ? "Connected" : "Paired") : "Not paired")
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Appearance")) {
                    HStack {
                        Label("Appearance", systemImage: "moon")
                        Spacer()
                        Text("Dark")
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("System")) {
                    Button { showAdvancedSettings = true } label: {
                        HStack {
                            Label("Backend status", systemImage: "cloud")
                            Spacer()
                            Circle()
                                .fill(apiManager.serverStatus == .online ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(apiManager.serverStatus.label)
                                .foregroundStyle(apiManager.serverStatus == .online ? .green : .secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    Button { showAdvancedSettings = true } label: {
                        Label("Data & export", systemImage: "externaldrive")
                    }
                    .foregroundStyle(.primary)
                    Button { showAbout = true } label: {
                        Label("About Flux", systemImage: "info.circle")
                    }
                    .foregroundStyle(.primary)
                }

                if showAdvancedSettings {
                Section(header: Text("More Options")) {
                    ShareLink(item: csvExport) {
                        Label("Export hydration CSV", systemImage: "square.and.arrow.up")
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
                    }
                    Toggle("Sync with WeatherKit", isOn: $syncWeatherKit)
                        .tint(FluxTheme.accent)

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
                }

                Section(header: Text("Backend Server")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mac IP Address")
                            .font(.geist(.caption))
                            .foregroundColor(.gray)
                        TextField("e.g. http://10.0.0.9:8000", text: $bindableAPI.serverBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    Text("Find your Mac IP: System Settings → Wi-Fi → Details → IP Address")
                        .font(.geist(.caption2))
                        .foregroundColor(.gray)

                    HStack(spacing: 8) {
                        Image(systemName: apiManager.serverStatus == .online ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(apiManager.serverStatus == .online ? .green : .secondary)
                        Text("Service status")
                        Spacer()
                        Text(apiManager.serverStatus.label)
                            .font(.geist(.caption))
                            .foregroundStyle(apiManager.serverStatus == .online ? .green : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Button {
                        Task { await apiManager.checkServer() }
                    } label: {
                        Label("Test backend connection", systemImage: "bolt.horizontal.circle")
                    }
                    .disabled(apiManager.serverStatus == .checking)
                }

                // MARK: Persona
                Section(header: Text("Notification Style")) {
                    Toggle(isOn: $bindableSettings.isRoastModeEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Roast Mode")
                                .font(.geist(.headline))
                            Text(bindableSettings.isRoastModeEnabled
                                 ? "Sarcastic & passive-aggressive 😈"
                                 : "Friendly & encouraging 🌱")
                                .font(.geist(.caption))
                                .foregroundColor(.gray)
                        }
                    }
                    .tint(FluxTheme.accent)
                    .onChange(of: bindableSettings.isRoastModeEnabled) { _, _ in
                        if remindersEnabled {
                            Task { await refreshReminderSchedule() }
                        } else {
                            Task { await notificationManager.requestAuthorization() }
                        }
                    }
                }
                }
            }
            .listRowBackground(FluxTheme.surface)
            .scrollContentBackground(.hidden)
            .background(FluxTheme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { healthManager.refreshAuthorization() }
            .sheet(isPresented: $showGoalEditor) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Daily goal")
                            .font(.geist(.headline))
                        Text("\(bindableSettings.baseGoalML.formatted()) ml")
                            .font(.geist(.title, weight: .bold).monospacedDigit())
                            .foregroundStyle(FluxTheme.accent)
                        Slider(value: Binding(
                            get: { Double(bindableSettings.baseGoalML) },
                            set: { bindableSettings.baseGoalML = Int($0) }
                        ), in: 1500...4000, step: 100)
                            .tint(FluxTheme.accent)
                        Spacer()
                    }
                    .padding(24)
                    .background(FluxTheme.background.ignoresSafeArea())
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showGoalEditor = false }
                        }
                    }
                }
                .presentationDetents([.height(260)])
            }
            .sheet(isPresented: $showAbout) {
                NavigationStack {
                    Form {
                        LabeledContent("Version", value: appVersion)
                        Button {
                            onboardingCompleted = false
                            showAbout = false
                        } label: {
                            Label("Replay introduction", systemImage: "book.closed")
                        }
                        Text("Flux is an estimation tool. Confirm unusual results and retake photos when the bottle is tilted, cropped, or reflective.")
                            .font(.geist(.caption))
                            .foregroundStyle(.secondary)
                    }
                    .scrollContentBackground(.hidden)
                    .background(FluxTheme.background)
                    .navigationTitle("About Flux")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showAbout = false }
                        }
                    }
                }
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
            await notificationManager.scheduleSmartReminders(
                records: waterRecords,
                goalML: currentSettings.baseGoalML,
                intervalHours: reminderIntervalHours,
                isRoastMode: currentSettings.isRoastModeEnabled
            )
        } else {
            await notificationManager.cancelReminders()
        }
    }
}
