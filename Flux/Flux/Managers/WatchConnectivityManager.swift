import Foundation
import SwiftData
import WatchConnectivity

@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    var isPaired = false
    var isReachable = false
    private var latestSnapshot: (total: Int, goal: Int)?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        isPaired = session.isPaired
        isReachable = session.isReachable
    }

    func sendWaterAdded(amountML: Int, todayTotalML: Int, goalML: Int) {
        sendTodaySnapshot(totalML: todayTotalML, goalML: goalML)
    }

    func sendTodaySnapshot(totalML: Int, goalML: Int) {
        guard WCSession.isSupported() else { return }
        latestSnapshot = (totalML, goalML)
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext([
            "today_total_ml": totalML,
            "goal_ml": goalML,
            "updated_at": Date().timeIntervalSince1970
        ])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.isPaired = session.isPaired
            self.isReachable = session.isReachable
            if let snapshot = self.latestSnapshot {
                self.sendTodaySnapshot(totalML: snapshot.total, goalML: snapshot.goal)
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            self.isPaired = session.isPaired
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["type"] as? String == "request_snapshot" {
            sendSnapshot(to: session)
            return
        }
        receiveWaterMessage(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receiveWaterMessage(userInfo)
    }

    private func receiveWaterMessage(_ message: [String: Any]) {
        guard message["type"] as? String == "water_added",
              let eventID = message["event_id"] as? String,
              let recordID = UUID(uuidString: eventID),
              let amount = message["amount_ml"] as? Int,
              (1...5000).contains(amount) else { return }

        Task { @MainActor in
            do {
                let container = try ModelContainer(for: WaterRecord.self, UserSettings.self, BottleProfile.self)
                let context = container.mainContext
                let existing = try context.fetch(FetchDescriptor<WaterRecord>(predicate: #Predicate { $0.id == recordID }))
                guard existing.isEmpty else { return }
                let record = WaterRecord(amountML: amount, id: recordID)
                context.insert(record)
                try context.save()
                let records = try context.fetch(FetchDescriptor<WaterRecord>())
                let today = Calendar.current.startOfDay(for: Date())
                let total = records.filter { $0.timestamp >= today }.reduce(0) { $0 + $1.amountML }
                let settings = try context.fetch(FetchDescriptor<UserSettings>()).first
                let goal = max(settings?.baseGoalML ?? 2000, 1)
                HydrationWidgetStore.update(totalML: total, goalML: goal)
                sendTodaySnapshot(totalML: total, goalML: goal)
                await HealthKitManager().syncWaterRecords([record])
                if UserDefaults.standard.bool(forKey: "flux_reminders_enabled") {
                    await NotificationManager().scheduleSmartReminders(
                        records: records,
                        goalML: goal,
                        intervalHours: UserDefaults.standard.integer(forKey: "flux_reminder_interval_hours"),
                        isRoastMode: settings?.isRoastModeEnabled ?? false
                    )
                }
            } catch {
                print("Watch water sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendSnapshot(to session: WCSession) {
        Task { @MainActor in
            do {
                let container = try ModelContainer(for: WaterRecord.self, UserSettings.self, BottleProfile.self)
                let context = container.mainContext
                let records = try context.fetch(FetchDescriptor<WaterRecord>())
                let start = Calendar.current.startOfDay(for: Date())
                let total = records
                    .filter { $0.timestamp >= start }
                    .reduce(0) { $0 + $1.amountML }
                let goal = max(try context.fetch(FetchDescriptor<UserSettings>()).first?.baseGoalML ?? 2000, 1)
                session.sendMessage([
                    "type": "snapshot",
                    "today_total_ml": total,
                    "goal_ml": goal
                ], replyHandler: nil)
            } catch {
                print("Watch snapshot sync failed: \(error.localizedDescription)")
            }
        }
    }
}
