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
    @AppStorage("flux_health_import_enabled") private var importExternalHealthWater = false
    @State private var syncWeatherKit = true
    @State private var showGoalEditor = false
    @State private var showHealthSheet = false
    @State private var showWatchSheet = false
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

                    Button { showHealthSheet = true } label: {
                        HStack {
                            Label("Apple Health", systemImage: "heart")
                            Spacer()
                            Text(healthRowStatus)
                                .font(.geist(.subheadline))
                                .foregroundStyle(healthRowColor)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button { showWatchSheet = true } label: {
                        HStack {
                            Label("Apple Watch", systemImage: "applewatch")
                            Spacer()
                            Text(watchManager.statusLabel)
                                .font(.geist(.subheadline))
                                .foregroundStyle(watchManager.isReachable ? .green : .secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
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
                        Task { _ = await watchManager.pushCurrentStateFromStore() }
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
            .onAppear {
                healthManager.refreshAuthorization()
                watchManager.refreshState()
            }
            .sheet(isPresented: $showHealthSheet) {
                healthSyncSheet
            }
            .sheet(isPresented: $showWatchSheet) {
                watchSyncSheet
            }
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

    private var healthRowStatus: String {
        if !healthManager.isSupported { return "Unavailable" }
        if !syncHealthKit { return "Off" }
        switch healthManager.authorizationStatus {
        case .authorized:
            let kcal = Int(healthManager.todayActiveEnergyBurned.rounded())
            return kcal > 0 ? "Synced · \(kcal) kcal" : "Synced"
        case .denied:
            return "Permission needed"
        case .notDetermined:
            return "Connect"
        case .unavailable:
            return "Unavailable"
        }
    }

    private var healthRowColor: Color {
        if syncHealthKit && healthManager.authorizationStatus == .authorized { return .green }
        if syncHealthKit && healthManager.authorizationStatus == .denied { return .orange }
        return .secondary
    }

    private var healthSyncSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("Sync Controls")) {
                    Toggle(isOn: $syncHealthKit) {
                        Label("Sync with Apple Health", systemImage: "heart.fill")
                    }
                    .tint(FluxTheme.accent)
                    .disabled(!healthManager.isSupported)
                    .onChange(of: syncHealthKit) { _, newValue in
                        if newValue {
                            healthManager.ensureEnabledTimestamp()
                            Task {
                                await healthManager.requestAuthorization()
                                if healthManager.isAuthorized {
                                    await healthManager.refreshAll(records: waterRecords, modelContext: modelContext)
                                } else if healthManager.authorizationStatus == .notDetermined {
                                    syncHealthKit = false
                                }
                            }
                        } else {
                            healthManager.todayActiveEnergyBurned = 0
                            healthManager.todayHealthWaterML = 0
                        }
                    }

                    if syncHealthKit {
                        Toggle(isOn: $importExternalHealthWater) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Import external Health water")
                                Text("Imports today's drinks logged in other apps without duplicating Flux entries.")
                                    .font(.geist(.caption2))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(FluxTheme.accent)
                        .onChange(of: importExternalHealthWater) { _, enabled in
                            if enabled {
                                Task {
                                    await healthManager.refreshAll(records: waterRecords, modelContext: modelContext)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Status")) {
                    LabeledContent("Permission") {
                        Text(healthManager.authorizationStatus.label)
                            .foregroundStyle(healthManager.isAuthorized ? .green : (healthManager.authorizationStatus == .denied ? .orange : .secondary))
                    }
                    if syncHealthKit {
                        let kcal = Int(healthManager.todayActiveEnergyBurned.rounded())
                        LabeledContent("Today active energy", value: "\(kcal) kcal (+\(kcal) ml goal)")
                        LabeledContent("Today in Apple Health", value: "\(healthManager.todayHealthWaterML.formatted()) ml")
                        LabeledContent("Synced entries", value: "\(healthManager.syncedRecordCount)")
                        if let lastSync = healthManager.lastSyncDate {
                            LabeledContent("Last synced", value: lastSync.formatted(date: .omitted, time: .shortened))
                        }
                    }
                }

                if let err = healthManager.lastErrorMessage {
                    Section {
                        Text(err)
                            .font(.geist(.caption))
                            .foregroundStyle(.orange)
                    }
                } else if healthManager.authorizationStatus == .denied {
                    Section {
                        Text("Apple Health permission was denied. Open the Health app → Sharing → Apps → Flux to allow Water and Active Energy access.")
                            .font(.geist(.caption))
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if !healthManager.isAuthorized && healthManager.isSupported {
                        Button {
                            Task {
                                syncHealthKit = true
                                healthManager.ensureEnabledTimestamp()
                                await healthManager.requestAuthorization()
                                if healthManager.isAuthorized {
                                    await healthManager.refreshAll(records: waterRecords, modelContext: modelContext)
                                }
                            }
                        } label: {
                            Label("Connect Apple Health", systemImage: "heart.text.square")
                        }
                    }

                    Button {
                        Task {
                            await healthManager.refreshAll(records: waterRecords, modelContext: modelContext)
                        }
                    } label: {
                        HStack {
                            Label("Sync Apple Health Now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if healthManager.isSyncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!syncHealthKit || !healthManager.isAuthorized || healthManager.isSyncing)
                }
            }
            .listRowBackground(FluxTheme.surface)
            .scrollContentBackground(.hidden)
            .background(FluxTheme.background)
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showHealthSheet = false }
                }
            }
            .onAppear {
                healthManager.refreshAuthorization()
                if syncHealthKit {
                    Task { await healthManager.refreshAll(records: waterRecords, modelContext: modelContext) }
                }
            }
        }
    }

    private var watchSyncSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("Connection")) {
                    LabeledContent("Status") {
                        Text(watchManager.statusLabel)
                            .foregroundStyle(watchManager.isReachable ? .green : .secondary)
                    }
                    LabeledContent("Apple Watch paired", value: watchManager.isPaired ? "Yes" : "No")
                    LabeledContent("Flux Watch app installed", value: watchManager.isWatchAppInstalled ? "Yes" : "No")
                    LabeledContent("Live reachable", value: watchManager.isReachable ? "Yes" : "Background queue")
                }

                Section(header: Text("Sync Activity")) {
                    if let lastSync = watchManager.lastSyncDate {
                        LabeledContent("Last pushed", value: lastSync.formatted(date: .omitted, time: .shortened))
                    } else {
                        LabeledContent("Last pushed", value: "Not yet")
                    }
                    if let summary = watchManager.lastReceivedSummary {
                        LabeledContent("Last Watch event", value: summary)
                    }
                    LabeledContent("Queued transfers", value: "\(watchManager.pendingTransferCount)")
                }

                if watchManager.isPaired && !watchManager.isWatchAppInstalled {
                    Section {
                        Text("Flux is bundled for Apple Watch. Open the Watch app on iPhone, scroll to Available Apps, and tap Install next to Flux.")
                            .font(.geist(.caption))
                            .foregroundStyle(.secondary)
                    }
                } else if !watchManager.isPaired {
                    Section {
                        Text("Pair an Apple Watch with this iPhone to log drinks, undo entries, and track your hydration ring from your wrist.")
                            .font(.geist(.caption))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { _ = await watchManager.pushCurrentStateFromStore() }
                    } label: {
                        Label("Sync Now to Apple Watch", systemImage: "applewatch.radiowaves.left.and.right")
                    }
                    .disabled(!watchManager.isPaired)
                }
            }
            .listRowBackground(FluxTheme.surface)
            .scrollContentBackground(.hidden)
            .background(FluxTheme.background)
            .navigationTitle("Apple Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showWatchSheet = false }
                }
            }
            .onAppear { watchManager.refreshState() }
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
