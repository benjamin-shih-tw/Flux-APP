import Foundation
import SwiftData
import WatchConnectivity

@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    var isPaired = false
    var isReachable = false

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
        guard WCSession.isSupported() else { return }
        let payload: [String: Any] = [
            "type": "water_added",
            "amount_ml": amountML,
            "today_total_ml": todayTotalML,
            "goal_ml": goalML
        ]
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil)
        }
        // Application context keeps the latest total available when the watch
        // is temporarily out of range; user info preserves the event itself.
        try? session.updateApplicationContext([
            "today_total_ml": todayTotalML,
            "goal_ml": goalML,
            "updated_at": Date().timeIntervalSince1970
        ])
        session.transferUserInfo(payload)
    }

    func sendTodaySnapshot(totalML: Int, goalML: Int) {
        guard WCSession.isSupported() else { return }
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
              let amount = message["amount_ml"] as? Int,
              (1...5000).contains(amount) else { return }

        Task { @MainActor in
            do {
                let container = try ModelContainer(for: WaterRecord.self, UserSettings.self, BottleProfile.self)
                let context = container.mainContext
                context.insert(WaterRecord(amountML: amount))
                try context.save()
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
