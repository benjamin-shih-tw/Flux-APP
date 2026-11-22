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
    @State private var showGoalEditor = false
    @State private var showHealthSheet = false
    @State private var showWatchSheet = false
    @State private var showAdvancedSettings = false
    @AppStorage("flux_show_diagnostics") private var showDiagnostics = false
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

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("你的每一天，持續流動")
                            .font(.fluxFont(size: 25, relativeTo: .title2, weight: .bold))
                        Text("調整目標、提醒與裝置整合，讓喝水更自然。")
                            .font(.fluxFont(.subheadline))
                            .foregroundStyle(FluxTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                }
                .listRowBackground(FluxTheme.background)

                Section(header: Text("每日習慣")) {
                    Button { showGoalEditor = true } label: {
                        HStack {
                            Label("每日目標", systemImage: "target")
                            Spacer()
                            Text("\(bindableSettings.baseGoalML.formatted()) ml")
                                .foregroundStyle(FluxTheme.accent)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Toggle(isOn: $remindersEnabled) {
                        Label("喝水提醒", systemImage: "bell")
                    }
                    .tint(FluxTheme.accent)
                    .onChange(of: remindersEnabled) { _, _ in
                        Task { await refreshReminderSchedule() }
                    }

                    if remindersEnabled {
                        Picker("提醒間隔", selection: $reminderIntervalHours) {
                            ForEach(1...4, id: \.self) { hours in
                                Text("每 \(hours) 小時").tag(hours)
                            }
                        }
                        .onChange(of: reminderIntervalHours) { _, _ in
                            Task { await refreshReminderSchedule() }
                        }
                        Toggle("趣味提醒語氣", isOn: $bindableSettings.isRoastModeEnabled)
                            .tint(FluxTheme.accent)
                            .onChange(of: bindableSettings.isRoastModeEnabled) { _, _ in
                                Task { await refreshReminderSchedule() }
                            }
                    }
                }

                Section(header: Text("裝置與健康")) {
                    Button { showHealthSheet = true } label: {
                        HStack {
                            Label("Apple 健康", systemImage: "heart")
                            Spacer()
                            Text(healthRowStatus)
                                .font(.fluxFont(.subheadline))
                                .foregroundStyle(healthRowColor)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button { showWatchSheet = true } label: {
                        HStack {
                            Label("Apple Watch", systemImage: "applewatch")
                            Spacer()
                            Text(watchManager.statusLabel)
                                .font(.fluxFont(.subheadline))
                                .foregroundStyle(watchManager.isReachable ? .green : .secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section(header: Text("資料與協助")) {
                    ShareLink(item: csvExport) {
                        Label("匯出飲水紀錄", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        onboardingCompleted = false
                    } label: {
                        Label("重播新手教學", systemImage: "book.closed")
                    }
                    Button { showAdvancedSettings = true } label: {
                        HStack {
                            Label("掃描服務與診斷", systemImage: "slider.horizontal.3")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    Button { showAbout = true } label: {
                        Label("關於 Flux", systemImage: "info.circle")
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Flux \(appVersion) · 照片水量為估算值，請確認異常結果。")
                }
            }
            .listRowBackground(FluxTheme.surface)
            .scrollContentBackground(.hidden)
            .background(FluxTheme.background)
            .navigationTitle("設定")
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
            .sheet(isPresented: $showAdvancedSettings) {
                advancedSettingsSheet
            }
            .sheet(isPresented: $showGoalEditor) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("每日目標")
                            .font(.fluxFont(.headline))
                        Text("\(bindableSettings.baseGoalML.formatted()) ml")
                            .font(.fluxFont(.title, weight: .bold).monospacedDigit())
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
                            Button("完成") { showGoalEditor = false }
                        }
                    }
                }
                .presentationDetents([.height(260)])
            }
            .sheet(isPresented: $showAbout) {
                NavigationStack {
                    Form {
                        LabeledContent("版本", value: appVersion)
                        Button {
                            onboardingCompleted = false
                            showAbout = false
                        } label: {
                            Label("重看使用教學", systemImage: "book.closed")
                        }
                        Text("Flux 的照片水量是估算值。若水瓶傾斜、畫面裁切或反光強烈，請重拍並確認結果。")
                            .font(.fluxFont(.caption))
                            .foregroundStyle(.secondary)
                    }
                    .scrollContentBackground(.hidden)
                    .background(FluxTheme.background)
                    .navigationTitle("關於 Flux")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showAbout = false }
                        }
                    }
                }
            }
        }
    }

    private var advancedSettingsSheet: some View {
        NavigationStack {
            @Bindable var bindableAPI = apiManager
            Form {
                Section {
                    Text("照片估算目前需要與 Mac 掃描服務位於同一個 Wi-Fi 網路。手動飲水記錄不需要連線。")
                        .font(.fluxFont(.subheadline))
                        .foregroundStyle(FluxTheme.muted)
                }

                Section(header: Text("掃描連線")) {
                    TextField("http://Mac.local:8000", text: $bindableAPI.serverBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    LabeledContent("服務狀態", value: apiManager.serverStatus.label)
                    Button {
                        Task { await apiManager.checkServer() }
                    } label: {
                        Label("檢查連線", systemImage: "arrow.clockwise")
                    }
                    .disabled(apiManager.serverStatus == .checking)
                }

                Section(header: Text("診斷工具")) {
                    Toggle("顯示掃描診斷資訊", isOn: $showDiagnostics)
                        .tint(FluxTheme.accent)
                    Text("開啟後才會在掃描結果顯示偵測疊圖、信心分數與演算法資訊。")
                        .font(.fluxFont(.caption))
                        .foregroundStyle(.secondary)
                    Button("同步今日總量至 Apple Watch") {
                        Task { _ = await watchManager.pushCurrentStateFromStore() }
                    }
                    .disabled(!watchManager.isPaired)
                }
            }
            .listRowBackground(FluxTheme.surface)
            .scrollContentBackground(.hidden)
            .background(FluxTheme.background)
            .navigationTitle("掃描服務與診斷")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showAdvancedSettings = false }
                }
            }
        }
    }

    private var healthRowStatus: String {
        if !healthManager.isSupported { return "無法使用" }
        if !syncHealthKit { return "未開啟" }
        switch healthManager.authorizationStatus {
        case .authorized:
            let kcal = Int(healthManager.todayActiveEnergyBurned.rounded())
            return kcal > 0 ? "已同步 · \(kcal) kcal" : "已同步"
        case .denied:
            return "需授權"
        case .notDetermined:
            return "可連結"
        case .unavailable:
            return "無法使用"
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
                Section(header: Text("同步設定")) {
                    Toggle(isOn: $syncHealthKit) {
                        Label("同步至 Apple 健康", systemImage: "heart.fill")
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
                                Text("匯入其他 App 的飲水")
                                Text("匯入其他 App 今天寫入健康資料的飲水，不重複計入 Flux 紀錄。")
                                    .font(.fluxFont(.caption2))
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

                Section(header: Text("狀態")) {
                    LabeledContent("權限") {
                        Text(healthManager.authorizationStatus.label)
                            .foregroundStyle(healthManager.isAuthorized ? .green : (healthManager.authorizationStatus == .denied ? .orange : .secondary))
                    }
                    if syncHealthKit {
                        let kcal = Int(healthManager.todayActiveEnergyBurned.rounded())
                        LabeledContent("今日活動熱量", value: "\(kcal) kcal (+\(kcal) ml goal)")
                        LabeledContent("健康資料今日飲水", value: "\(healthManager.todayHealthWaterML.formatted()) ml")
                        LabeledContent("已同步紀錄", value: "\(healthManager.syncedRecordCount)")
                        if let lastSync = healthManager.lastSyncDate {
                            LabeledContent("上次同步", value: lastSync.formatted(date: .omitted, time: .shortened))
                        }
                    }
                }

                if let err = healthManager.lastErrorMessage {
                    Section {
                        Text(err)
                            .font(.fluxFont(.caption))
                            .foregroundStyle(.orange)
                    }
                } else if healthManager.authorizationStatus == .denied {
                    Section {
                        Text("Apple 健康尚未授權。請到「健康」App 的分享設定中允許 Flux 讀取活動熱量與寫入飲水。")
                            .font(.fluxFont(.caption))
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
                            Label("連結 Apple 健康", systemImage: "heart.text.square")
                        }
                    }

                    Button {
                        Task {
                            await healthManager.refreshAll(records: waterRecords, modelContext: modelContext)
                        }
                    } label: {
                        HStack {
                            Label("立即同步 Apple 健康", systemImage: "arrow.triangle.2.circlepath")
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
            .navigationTitle("Apple 健康")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showHealthSheet = false }
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
                Section(header: Text("連線")) {
                    LabeledContent("狀態") {
                        Text(watchManager.statusLabel)
                            .foregroundStyle(watchManager.isReachable ? .green : .secondary)
                    }
                    LabeledContent("已配對 Apple Watch", value: watchManager.isPaired ? "是" : "否")
                    LabeledContent("已安裝 Flux Watch", value: watchManager.isWatchAppInstalled ? "是" : "否")
                    LabeledContent("即時連線", value: watchManager.isReachable ? "是" : "背景佇列")
                }

                Section(header: Text("同步紀錄")) {
                    if let lastSync = watchManager.lastSyncDate {
                        LabeledContent("上次推送", value: lastSync.formatted(date: .omitted, time: .shortened))
                    } else {
                        LabeledContent("上次推送", value: "尚未")
                    }
                    if let summary = watchManager.lastReceivedSummary {
                        LabeledContent("上次手錶操作", value: summary)
                    }
                    LabeledContent("待傳輸筆數", value: "\(watchManager.pendingTransferCount)")
                }

                if watchManager.isPaired && !watchManager.isWatchAppInstalled {
                    Section {
                        Text("Flux 已包含 Apple Watch App。請在 iPhone 的 Watch App 中找到 Flux 並點選安裝。")
                            .font(.fluxFont(.caption))
                            .foregroundStyle(.secondary)
                    }
                } else if !watchManager.isPaired {
                    Section {
                        Text("配對 Apple Watch 後，可以在手錶記錄飲水、復原上一筆並查看今日進度。")
                            .font(.fluxFont(.caption))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { _ = await watchManager.pushCurrentStateFromStore() }
                    } label: {
                        Label("立即同步 Apple Watch", systemImage: "applewatch.radiowaves.left.and.right")
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
                    Button("完成") { showWatchSheet = false }
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
