import Foundation
import WatchConnectivity
import WatchKit

struct WatchWaterEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let amountML: Int
    let timestamp: Date
}

final class FluxWatchConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    private enum StorageKey {
        static let total = "flux_watch_today_total_ml"
        static let goal = "flux_watch_goal_ml"
        static let energy = "flux_watch_active_energy_kcal"
        static let streak = "flux_watch_streak_days"
        static let dayKey = "flux_watch_day_key"
        static let recent = "flux_watch_recent_entries"
        static let pending = "flux_watch_pending_event_ids"
        static let lastSync = "flux_watch_last_sync_at"
    }

    @Published var todayTotalML = 0
    @Published var goalML = 2000
    @Published var activeEnergyKCal = 0
    @Published var streakDays = 0
    @Published var recentEntries: [WatchWaterEntry] = []
    @Published var pendingEventCount = 0
    @Published var isReachable = false
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?

    private var pendingEventIDs: Set<String> = []
    private var storedDayKey: String = ""

    override init() {
        super.init()
        loadPersistedState()
        rolloverDayIfNeeded()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        isReachable = session.isReachable
    }

    var canUndoLast: Bool {
        rolloverDayIfNeeded()
        return !recentEntries.isEmpty
    }

    var latestEntry: WatchWaterEntry? {
        recentEntries.first
    }

    func requestSnapshot() {
        rolloverDayIfNeeded()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        if !session.receivedApplicationContext.isEmpty {
            applySnapshot(session.receivedApplicationContext)
        }

        guard session.isReachable else { return }
        isSyncing = true
        session.sendMessage(
            ["type": "request_snapshot"],
            replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    self?.isSyncing = false
                    self?.applySnapshot(reply)
                }
            },
            errorHandler: { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isSyncing = false
                }
            }
        )
    }

    func addWater(_ amountML: Int) {
        guard (1...5000).contains(amountML) else { return }
        rolloverDayIfNeeded()

        let previousTotal = todayTotalML
        let entry = WatchWaterEntry(id: UUID(), amountML: amountML, timestamp: Date())
        todayTotalML += amountML
        recentEntries.insert(entry, at: 0)
        if recentEntries.count > 10 {
            recentEntries = Array(recentEntries.prefix(10))
        }

        let crossedGoal = previousTotal < goalML && todayTotalML >= goalML
        WKInterfaceDevice.current().play(crossedGoal ? .success : .click)

        let eventID = entry.id.uuidString
        pendingEventIDs.insert(eventID)
        pendingEventCount = pendingEventIDs.count
        persistState()

        let payload: [String: Any] = [
            "type": "water_added",
            "event_id": eventID,
            "amount_ml": amountML,
            "timestamp": entry.timestamp.timeIntervalSince1970,
            "today_total_ml": todayTotalML,
            "goal_ml": goalML
        ]
        deliverEvent(payload, eventID: eventID)
    }

    func undoLastEntry() {
        rolloverDayIfNeeded()
        guard let last = recentEntries.first else { return }
        recentEntries.removeFirst()
        todayTotalML = max(0, todayTotalML - last.amountML)
        WKInterfaceDevice.current().play(.directionDown)

        let eventID = last.id.uuidString
        pendingEventIDs.insert(eventID)
        pendingEventCount = pendingEventIDs.count
        persistState()

        let payload: [String: Any] = [
            "type": "water_deleted",
            "event_id": eventID,
            "timestamp": Date().timeIntervalSince1970
        ]
        deliverEvent(payload, eventID: eventID)
    }

    private func deliverEvent(_ payload: [String: Any], eventID: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.activationState == .activated, session.isReachable {
            session.sendMessage(
                payload,
                replyHandler: { [weak self] reply in
                    DispatchQueue.main.async {
                        self?.pendingEventIDs.remove(eventID)
                        self?.pendingEventCount = self?.pendingEventIDs.count ?? 0
                        self?.applySnapshot(reply)
                    }
                },
                errorHandler: { [weak self] _ in
                    session.transferUserInfo(payload)
                    DispatchQueue.main.async {
                        self?.pendingEventCount = max(
                            self?.pendingEventIDs.count ?? 0,
                            session.outstandingUserInfoTransfers.count
                        )
                    }
                }
            )
        } else {
            session.transferUserInfo(payload)
            pendingEventCount = max(pendingEventIDs.count, session.outstandingUserInfoTransfers.count)
        }
    }

    // MARK: - WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            if !session.receivedApplicationContext.isEmpty {
                self.applySnapshot(session.receivedApplicationContext)
            }
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

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let finishedID = userInfoTransfer.userInfo["event_id"] as? String
        DispatchQueue.main.async {
            if error == nil, let finishedID {
                self.pendingEventIDs.remove(finishedID)
            }
            self.pendingEventCount = max(self.pendingEventIDs.count, session.outstandingUserInfoTransfers.count)
            self.persistState()
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.applySnapshot(message)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.applySnapshot(applicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async {
            self.applySnapshot(userInfo)
        }
    }

    // MARK: - State & Persistence

    private func applySnapshot(_ message: [String: Any]) {
        rolloverDayIfNeeded()
        guard let total = intValue(message["today_total_ml"]) else { return }

        let todayKey = Self.dayKey(for: Date())
        if let incomingDay = message["day_key"] as? String, incomingDay != todayKey {
            // Ignore stale snapshot from a previous day while still adopting goal.
            if let goal = intValue(message["goal_ml"]), goal > 0 {
                goalML = goal
            }
            persistState()
            return
        }

        // Only overwrite local total when there are no unsynced offline edits,
        // or when iPhone reflects a higher/authoritative confirmed snapshot.
        if pendingEventIDs.isEmpty {
            todayTotalML = max(0, total)
        } else {
            todayTotalML = max(todayTotalML, total)
        }

        if let goal = intValue(message["goal_ml"]), goal > 0 {
            goalML = goal
        }
        if let energy = intValue(message["active_energy_kcal"]) {
            activeEnergyKCal = max(0, energy)
        }
        if let streak = intValue(message["streak_days"]) {
            streakDays = max(0, streak)
        }

        if let rawEntries = message["recent_entries"] as? [[String: Any]], pendingEventIDs.isEmpty {
            let decoded: [WatchWaterEntry] = rawEntries.compactMap { item in
                guard let idStr = item["id"] as? String,
                      let uuid = UUID(uuidString: idStr),
                      let amount = intValue(item["amount_ml"]),
                      let ts = doubleValue(item["timestamp"]) else {
                    return nil
                }
                return WatchWaterEntry(id: uuid, amountML: amount, timestamp: Date(timeIntervalSince1970: ts))
            }
            recentEntries = decoded
        }

        storedDayKey = todayKey
        lastSyncDate = Date()
        persistState()
    }

    private func rolloverDayIfNeeded() {
        let today = Self.dayKey(for: Date())
        guard storedDayKey != today else { return }
        storedDayKey = today
        todayTotalML = 0
        activeEnergyKCal = 0
        recentEntries = []
        persistState()
    }

    private func loadPersistedState() {
        let defaults = UserDefaults.standard
        storedDayKey = defaults.string(forKey: StorageKey.dayKey) ?? Self.dayKey(for: Date())
        todayTotalML = defaults.integer(forKey: StorageKey.total)
        let savedGoal = defaults.integer(forKey: StorageKey.goal)
        goalML = savedGoal > 0 ? savedGoal : 2000
        activeEnergyKCal = defaults.integer(forKey: StorageKey.energy)
        streakDays = defaults.integer(forKey: StorageKey.streak)
        lastSyncDate = defaults.object(forKey: StorageKey.lastSync) as? Date
        pendingEventIDs = Set(defaults.stringArray(forKey: StorageKey.pending) ?? [])
        pendingEventCount = pendingEventIDs.count

        if let data = defaults.data(forKey: StorageKey.recent),
           let decoded = try? JSONDecoder().decode([WatchWaterEntry].self, from: data) {
            recentEntries = decoded
        }
    }

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(storedDayKey, forKey: StorageKey.dayKey)
        defaults.set(todayTotalML, forKey: StorageKey.total)
        defaults.set(goalML, forKey: StorageKey.goal)
        defaults.set(activeEnergyKCal, forKey: StorageKey.energy)
        defaults.set(streakDays, forKey: StorageKey.streak)
        defaults.set(Array(pendingEventIDs), forKey: StorageKey.pending)
        if let lastSyncDate {
            defaults.set(lastSyncDate, forKey: StorageKey.lastSync)
        }
        if let data = try? JSONEncoder().encode(recentEntries) {
            defaults.set(data, forKey: StorageKey.recent)
        }
    }

    private static func dayKey(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let v = raw as? Int { return v }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    private func doubleValue(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }
}
