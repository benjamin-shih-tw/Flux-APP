import SwiftUI
import SwiftData

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(HealthKitManager.self) private var healthManager
    @Environment(WeatherKitManager.self) private var weatherManager
    @Environment(DynamicGoalEngine.self) private var goalEngine
    @Environment(NotificationManager.self) private var notificationManager
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Query(sort: \WaterRecord.timestamp, order: .reverse) private var waterRecords: [WaterRecord]
    @Query private var settingsList: [UserSettings]
    @AppStorage("flux_reminders_enabled") private var remindersEnabled = false
    @AppStorage("flux_reminder_interval_hours") private var reminderIntervalHours = 2
    @State private var selectedTab: FluxTab = .home

    private var recordSignature: [String] {
        waterRecords.map { "\($0.id):\($0.amountML):\($0.timestamp.timeIntervalSince1970)" }
    }

    var body: some View {
        ZStack {
            FluxTheme.background.ignoresSafeArea()
            Group {
                switch selectedTab {
                case .home: DashboardView()
                case .scan: ARScannerView()
                case .streak: AnalyticsView()
                case .settings: SettingsView()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(FluxTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Image(systemName: selectedTab == tab ? tab.selectedSymbol : tab.symbol)
                            .font(.system(size: 22, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .foregroundStyle(selectedTab == tab ? FluxTheme.accent : Color.white.opacity(0.72))
                            .background {
                                if selectedTab == tab {
                                    Capsule()
                                        .fill(FluxTheme.accent.opacity(0.12))
                                        .overlay {
                                            Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
                                        }
                                        .shadow(color: FluxTheme.accent.opacity(0.25), radius: 12, y: 5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(5)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 7)
        }
        .tint(FluxTheme.accent)
        .preferredColorScheme(.dark)
        .task { await syncIntegrations() }
        .onChange(of: recordSignature) { _, _ in Task { await syncIntegrations() } }
        .onChange(of: settingsList.first?.baseGoalML) { _, _ in Task { await syncIntegrations() } }
        .onChange(of: healthManager.todayActiveEnergyBurned) { _, _ in pushWatchAndWidgetSnapshot() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                watchManager.refreshState()
                Task { await syncIntegrations() }
            }
        }
    }

    private func effectiveDailyGoal() -> Int {
        let base = max(settingsList.first?.baseGoalML ?? 2000, 1)
        goalEngine.baseGoalML = Double(base)
        return goalEngine.calculateTodayGoal(
            activeEnergyKCal: healthManager.todayActiveEnergyBurned,
            apparentTempCelsius: weatherManager.currentApparentTemperature
        )
    }

    private func pushWatchAndWidgetSnapshot() {
        let today = Calendar.current.startOfDay(for: Date())
        let todayRecords = waterRecords.filter { $0.timestamp >= today }
        let total = todayRecords.reduce(0) { $0 + $1.amountML }
        let goal = effectiveDailyGoal()
        HydrationWidgetStore.update(totalML: total, goalML: goal)
        watchManager.sendTodaySnapshot(
            totalML: total,
            goalML: goal,
            activeEnergyKCal: Int(healthManager.todayActiveEnergyBurned.rounded()),
            streakDays: WatchHydrationCodec.currentStreak(records: waterRecords, goalML: goal),
            recentEntries: todayRecords.prefix(6).map { ($0.id, $0.amountML, $0.timestamp) }
        )
    }

    private func syncIntegrations() async {
        await healthManager.refreshAll(records: waterRecords, modelContext: modelContext)
        pushWatchAndWidgetSnapshot()
        let settings = settingsList.first
        let goal = effectiveDailyGoal()
        if remindersEnabled {
            await notificationManager.scheduleSmartReminders(
                records: waterRecords,
                goalML: goal,
                intervalHours: reminderIntervalHours,
                isRoastMode: settings?.isRoastModeEnabled ?? false
            )
        }
    }
}

private enum FluxTab: String, CaseIterable, Identifiable {
    case home, scan, streak, settings

    var id: Self { self }
    var title: String {
        switch self {
        case .home: "首頁"
        case .scan: "掃描"
        case .streak: "趨勢"
        case .settings: "設定"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .scan: "viewfinder"
        case .streak: "chart.bar"
        case .settings: "gearshape"
        }
    }
    var selectedSymbol: String {
        switch self {
        case .home: "house.fill"
        case .scan: "viewfinder"
        case .streak: "chart.bar.fill"
        case .settings: "gearshape.fill"
        }
    }
}
