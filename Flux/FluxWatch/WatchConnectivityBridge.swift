import Foundation
import WatchConnectivity

final class FluxWatchConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published var todayTotalML = 0
    @Published var goalML = 2000
    @Published var isReachable = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        isReachable = session.isReachable
    }

    func requestSnapshot() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["type": "request_snapshot"], replyHandler: nil)
    }

    func addWater(_ amountML: Int) {
        guard (1...5000).contains(amountML) else { return }
        todayTotalML += amountML
        let payload: [String: Any] = [
            "type": "water_added",
            "amount_ml": amountML,
            "today_total_ml": todayTotalML,
            "goal_ml": goalML
        ]
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil)
        } else {
            session.transferUserInfo(payload)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            if session.isReachable {
                self.requestSnapshot()
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            if session.isReachable {
                self.requestSnapshot()
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    private func handle(_ message: [String: Any]) {
        guard let total = message["today_total_ml"] as? Int else { return }
        let goal = message["goal_ml"] as? Int ?? goalML
        DispatchQueue.main.async {
            self.todayTotalML = total
            self.goalML = max(goal, 1)
        }
    }
}
