import Foundation
import SwiftData
@preconcurrency import WatchConnectivity

/// Pure payload codec and streak logic shared by WatchConnectivityManager and unit tests.
enum WatchHydrationCodec {
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func parseWaterAdded(
        _ payload: [String: Any],
        now: Date = Date()
    ) -> (id: UUID, amountML: Int, timestamp: Date)? {
        guard payload["type"] as? String == "water_added",
              let eventID = payload["event_id"] as? String,
              let recordID = UUID(uuidString: eventID),
              let amount = intValue(payload["amount_ml"]),
              (1...5000).contains(amount) else {
            return nil
        }

        let resolvedDate: Date
        if let rawTs = doubleValue(payload["timestamp"]), rawTs.isFinite {
            let candidate = Date(timeIntervalSince1970: rawTs)
            let earliest = now.addingTimeInterval(-7 * 24 * 3600)
            let latest = now.addingTimeInterval(60)
            resolvedDate = (candidate >= earliest && candidate <= latest) ? candidate : now
        } else {
            resolvedDate = now
        }
        return (recordID, amount, resolvedDate)
    }

    static func parseWaterDeleted(_ payload: [String: Any]) -> UUID? {
        guard payload["type"] as? String == "water_deleted",
              let eventID = payload["event_id"] as? String,
              let recordID = UUID(uuidString: eventID) else {
            return nil
        }
        return recordID
    }

    static func makeSnapshotPayload(
        totalML: Int,
        goalML: Int,
        activeEnergyKCal: Int = 0,
        streakDays: Int = 0,
        recentEntries: [(id: UUID, amountML: Int, timestamp: Date)] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String: Any] {
        let serializedEntries: [[String: Any]] = recentEntries.prefix(6).map { entry in
            [
                "id": entry.id.uuidString,
                "amount_ml": entry.amountML,
                "timestamp": entry.timestamp.timeIntervalSince1970
            ]
        }
        return [
            "type": "snapshot",
            "today_total_ml": max(0, totalML),
            "goal_ml": max(1, goalML),
            "active_energy_kcal": max(0, activeEnergyKCal),
            "streak_days": max(0, streakDays),
            "recent_entries": serializedEntries,
            "day_key": dayKey(for: now, calendar: calendar),
            "updated_at": now.timeIntervalSince1970
        ]
    }

    static func currentStreak(
        records: [WaterRecord],
        goalML: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let safeGoal = max(goalML, 1)
        let totalsByDay = Dictionary(grouping: records) {
            calendar.startOfDay(for: $0.timestamp)
        }
        .mapValues { dayRecords in dayRecords.reduce(0) { $0 + $1.amountML } }

        var cursor = calendar.startOfDay(for: now)
        if (totalsByDay[cursor] ?? 0) < safeGoal {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                return 0
            }
            cursor = yesterday
        }

        var streak = 0
        while (totalsByDay[cursor] ?? 0) >= safeGoal {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return streak
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }
}

@MainActor
@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    var isSupported = false
    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false
    var lastSyncDate: Date?
    var lastReceivedSummary: String?
    var pendingTransferCount = 0

    private var modelContainer: ModelContainer?
    private weak var healthManager: HealthKitManager?
    private weak var dynamicGoalEngine: DynamicGoalEngine?
    private weak var weatherManager: WeatherKitManager?
    private weak var notificationManager: NotificationManager?
    private var latestSnapshotPayload: [String: Any]?

    var statusLabel: String {
        guard isSupported else { return "無法使用" }
        guard isPaired else { return "尚未配對" }
        guard isWatchAppInstalled else { return "需在手錶安裝" }
        return isReachable ? "已連線" : "已配對 · 背景同步"
    }

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        isSupported = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        refreshSessionState(session)
    }

    /// Inject the app's shared SwiftData container and managers so drinks logged
    /// or undone on Apple Watch immediately update SwiftUI views, HealthKit,
    /// widgets, and reminders in the same store.
    func configure(
        modelContainer: ModelContainer,
        healthManager: HealthKitManager,
        dynamicGoalEngine: DynamicGoalEngine,
        weatherManager: WeatherKitManager,
        notificationManager: NotificationManager
    ) {
        self.modelContainer = modelContainer
        self.healthManager = healthManager
        self.dynamicGoalEngine = dynamicGoalEngine
        self.weatherManager = weatherManager
        self.notificationManager = notificationManager
    }

    func sendWaterAdded(amountML: Int, todayTotalML: Int, goalML: Int) {
        if modelContainer != nil {
            Task { await pushCurrentStateFromStore() }
        } else {
            sendTodaySnapshot(totalML: todayTotalML, goalML: goalML)
        }
    }

    func sendTodaySnapshot(
        totalML: Int,
        goalML: Int,
        activeEnergyKCal: Int = 0,
        streakDays: Int = 0,
        recentEntries: [(id: UUID, amountML: Int, timestamp: Date)] = []
    ) {
        guard WCSession.isSupported() else { return }
        let payload = WatchHydrationCodec.makeSnapshotPayload(
            totalML: totalML,
            goalML: goalML,
            activeEnergyKCal: activeEnergyKCal,
            streakDays: streakDays,
            recentEntries: recentEntries
        )
        latestSnapshotPayload = payload
        let session = WCSession.default
        refreshSessionState(session)
        guard session.activationState == .activated, session.isPaired else { return }

        do {
            try session.updateApplicationContext(payload)
            lastSyncDate = Date()
        } catch {
            print("Watch applicationContext update failed: \(error.localizedDescription)")
        }

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                print("Watch live snapshot message failed: \(error.localizedDescription)")
            }
        }
    }

    /// Build and push the authoritative snapshot from the shared SwiftData store.
    @discardableResult
    func pushCurrentStateFromStore() async -> [String: Any]? {
        guard let snapshot = buildCurrentStoreSnapshot() else { return nil }
        sendTodaySnapshot(
            totalML: snapshot.totalML,
            goalML: snapshot.goalML,
            activeEnergyKCal: snapshot.activeEnergyKCal,
            streakDays: snapshot.streakDays,
            recentEntries: snapshot.recentEntries
        )
        return latestSnapshotPayload
    }

    func refreshState() {
        guard WCSession.isSupported() else { return }
        refreshSessionState(WCSession.default)
    }

    private func refreshSessionState(_ session: WCSession) {
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
        pendingTransferCount = session.outstandingUserInfoTransfers.count
    }

    private func resolveContainer() throws -> ModelContainer {
        if let modelContainer { return modelContainer }
        let fallback = try ModelContainer(for: WaterRecord.self, UserSettings.self, BottleProfile.self)
        modelContainer = fallback
        return fallback
    }

    private func effectiveGoalML(settings: UserSettings?) -> Int {
        let base = max(settings?.baseGoalML ?? 2000, 1)
        guard let engine = dynamicGoalEngine else { return base }
        engine.baseGoalML = Double(base)
        return engine.calculateTodayGoal(
            activeEnergyKCal: healthManager?.todayActiveEnergyBurned ?? 0,
            apparentTempCelsius: weatherManager?.currentApparentTemperature
        )
    }

    private func buildCurrentStoreSnapshot() -> (
        totalML: Int,
        goalML: Int,
        activeEnergyKCal: Int,
        streakDays: Int,
        recentEntries: [(id: UUID, amountML: Int, timestamp: Date)]
    )? {
        do {
            let container = try resolveContainer()
            let context = container.mainContext
            let records = try context.fetch(FetchDescriptor<WaterRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            ))
            let settings = try context.fetch(FetchDescriptor<UserSettings>()).first
            let goal = effectiveGoalML(settings: settings)
            let start = Calendar.current.startOfDay(for: Date())
            let todayRecords = records.filter { $0.timestamp >= start }
            let total = todayRecords.reduce(0) { $0 + $1.amountML }
            let energyKCal = Int((healthManager?.todayActiveEnergyBurned ?? 0).rounded())
            let streak = WatchHydrationCodec.currentStreak(records: records, goalML: goal)
            let recent = todayRecords.prefix(6).map { ($0.id, $0.amountML, $0.timestamp) }
            return (total, goal, energyKCal, streak, recent)
        } catch {
            print("Watch snapshot build failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func handleIncomingPayload(_ message: [String: Any]) async -> [String: Any] {
        let type = message["type"] as? String ?? ""

        if type == "request_snapshot" {
            if let payload = await pushCurrentStateFromStore() {
                return payload
            }
            return latestSnapshotPayload ?? WatchHydrationCodec.makeSnapshotPayload(totalML: 0, goalML: 2000)
        }

        if let added = WatchHydrationCodec.parseWaterAdded(message) {
            await applyWatchWaterAdded(id: added.id, amountML: added.amountML, timestamp: added.timestamp)
            return latestSnapshotPayload ?? WatchHydrationCodec.makeSnapshotPayload(totalML: 0, goalML: 2000)
        }

        if let deletedID = WatchHydrationCodec.parseWaterDeleted(message) {
            await applyWatchWaterDeleted(id: deletedID)
            return latestSnapshotPayload ?? WatchHydrationCodec.makeSnapshotPayload(totalML: 0, goalML: 2000)
        }

        return latestSnapshotPayload ?? WatchHydrationCodec.makeSnapshotPayload(totalML: 0, goalML: 2000)
    }

    private func applyWatchWaterAdded(id: UUID, amountML: Int, timestamp: Date) async {
        do {
            let container = try resolveContainer()
            let context = container.mainContext
            let existing = try context.fetch(FetchDescriptor<WaterRecord>(predicate: #Predicate { $0.id == id }))
            if existing.isEmpty {
                let record = WaterRecord(amountML: amountML, timestamp: timestamp, id: id)
                context.insert(record)
                try context.save()
                lastReceivedSummary = "Logged +\(amountML) ml from Watch"
                if let health = healthManager {
                    await health.syncWaterRecords([record])
                    await health.fetchTodayHealthWater()
                } else {
                    await HealthKitManager().syncWaterRecords([record])
                }
            }
            await refreshDownstreamIntegrations()
        } catch {
            print("Watch water_added sync failed: \(error.localizedDescription)")
        }
    }

    private func applyWatchWaterDeleted(id: UUID) async {
        do {
            let container = try resolveContainer()
            let context = container.mainContext
            let matches = try context.fetch(FetchDescriptor<WaterRecord>(predicate: #Predicate { $0.id == id }))
            for record in matches {
                context.delete(record)
            }
            if !matches.isEmpty {
                try context.save()
                lastReceivedSummary = "Undid entry from Watch"
            }
            if let health = healthManager {
                await health.deleteWaterRecord(id: id)
            } else {
                await HealthKitManager().deleteWaterRecord(id: id)
            }
            await refreshDownstreamIntegrations()
        } catch {
            print("Watch water_deleted sync failed: \(error.localizedDescription)")
        }
    }

    private func refreshDownstreamIntegrations() async {
        do {
            let container = try resolveContainer()
            let context = container.mainContext
            let records = try context.fetch(FetchDescriptor<WaterRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            ))
            let settings = try context.fetch(FetchDescriptor<UserSettings>()).first
            let goal = effectiveGoalML(settings: settings)
            let start = Calendar.current.startOfDay(for: Date())
            let todayRecords = records.filter { $0.timestamp >= start }
            let total = todayRecords.reduce(0) { $0 + $1.amountML }

            HydrationWidgetStore.update(totalML: total, goalML: goal)
            sendTodaySnapshot(
                totalML: total,
                goalML: goal,
                activeEnergyKCal: Int((healthManager?.todayActiveEnergyBurned ?? 0).rounded()),
                streakDays: WatchHydrationCodec.currentStreak(records: records, goalML: goal),
                recentEntries: todayRecords.prefix(6).map { ($0.id, $0.amountML, $0.timestamp) }
            )

            if UserDefaults.standard.bool(forKey: "flux_reminders_enabled") {
                let manager = notificationManager ?? NotificationManager()
                await manager.scheduleSmartReminders(
                    records: records,
                    goalML: goal,
                    intervalHours: UserDefaults.standard.integer(forKey: "flux_reminder_interval_hours"),
                    isRoastMode: settings?.isRoastModeEnabled ?? false
                )
            }
        } catch {
            print("Downstream integration refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.refreshSessionState(session)
            if activationState == .activated {
                if self.modelContainer != nil {
                    await self.pushCurrentStateFromStore()
                } else if let payload = self.latestSnapshotPayload, session.isPaired {
                    try? session.updateApplicationContext(payload)
                }
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshSessionState(session)
            if session.isReachable, self.modelContainer != nil {
                await self.pushCurrentStateFromStore()
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshSessionState(session)
            if session.isPaired, session.isWatchAppInstalled, self.modelContainer != nil {
                await self.pushCurrentStateFromStore()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        Task { @MainActor in
            self.refreshSessionState(session)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        nonisolated(unsafe) let box = message
        Task { @MainActor in
            _ = await self.handleIncomingPayload(box)
            self.refreshSessionState(session)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        nonisolated(unsafe) let box = message
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            let response = await self.handleIncomingPayload(box)
            self.refreshSessionState(session)
            reply(response)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        nonisolated(unsafe) let box = userInfo
        Task { @MainActor in
            _ = await self.handleIncomingPayload(box)
            self.refreshSessionState(session)
        }
    }
}
