import Foundation
import UserNotifications
import Observation

/// Smart reminder scheduler that adapts to user behavior and context.
///
/// Features:
/// - Configurable base interval (1h / 1.5h / 2h / 3h)
/// - Resets countdown after every water log
/// - Quiet hours (sleep schedule)
/// - Contextual boost: shortens interval during hot weather or after exercise
@Observable
final class ReminderScheduler {
    private let center = UNUserNotificationCenter.current()

    // MARK: - User Preferences (persisted via UserDefaults)

    var reminderEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "reminderEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "reminderEnabled")
            if newValue { scheduleNext() } else { cancelAll() }
        }
    }

    /// Base interval in seconds between reminders.
    var baseIntervalSeconds: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: "reminderBaseInterval")
            return stored > 0 ? stored : 7200 // Default 2 hours
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "reminderBaseInterval")
            reschedule()
        }
    }

    /// Index into `intervalOptions` for the picker UI.
    var selectedIntervalIndex: Int {
        get { intervalOptions.firstIndex(where: { $0.seconds == baseIntervalSeconds }) ?? 2 }
        set {
            guard newValue < intervalOptions.count else { return }
            baseIntervalSeconds = intervalOptions[newValue].seconds
        }
    }

    /// Hour (0-23) when quiet hours begin (bedtime).
    var quietStartHour: Int {
        get { UserDefaults.standard.object(forKey: "quietStartHour") as? Int ?? 22 }
        set { UserDefaults.standard.set(newValue, forKey: "quietStartHour"); reschedule() }
    }

    /// Hour (0-23) when quiet hours end (wake time).
    var quietEndHour: Int {
        get { UserDefaults.standard.object(forKey: "quietEndHour") as? Int ?? 7 }
        set { UserDefaults.standard.set(newValue, forKey: "quietEndHour"); reschedule() }
    }

    // MARK: - Interval Options

    struct IntervalOption: Identifiable {
        let id = UUID()
        let label: String
        let seconds: TimeInterval
    }

    let intervalOptions: [IntervalOption] = [
        IntervalOption(label: "1 hour", seconds: 3600),
        IntervalOption(label: "1.5 hours", seconds: 5400),
        IntervalOption(label: "2 hours", seconds: 7200),
        IntervalOption(label: "3 hours", seconds: 10800),
    ]

    // MARK: - Context Boost

    /// When true, the next scheduled interval is shortened by 30% (hot weather / post-workout).
    var contextBoostActive: Bool = false

    // MARK: - Scheduling

    /// Call after every water log to reset the countdown.
    func userDidLogWater() {
        guard reminderEnabled else { return }
        scheduleNext()
    }

    /// Evaluate environment and toggle the context boost.
    func updateContextBoost(apparentTempCelsius: Double?, activeEnergyKCal: Double) {
        let hot = (apparentTempCelsius ?? 0) > 30
        let activeWorkout = activeEnergyKCal > 300
        contextBoostActive = hot || activeWorkout
        if reminderEnabled { reschedule() }
    }

    /// Schedule the next reminder notification, replacing any pending one.
    func scheduleNext() {
        cancelAll()

        var interval = baseIntervalSeconds
        if contextBoostActive {
            interval *= 0.7 // 30% shorter
        }

        // If current time is within quiet hours, schedule for the end of quiet hours instead.
        let now = Date()
        let cal = Calendar.current
        let currentHour = cal.component(.hour, from: now)

        if isInQuietHours(hour: currentHour) {
            // Schedule at wake time tomorrow (or today if wake time hasn't passed yet).
            guard let wakeDate = nextWakeDate(from: now) else { return }
            let wakeInterval = wakeDate.timeIntervalSince(now)
            scheduleNotification(after: max(wakeInterval, 60))
        } else {
            // Ensure the scheduled time doesn't fall in quiet hours.
            let fireDate = now.addingTimeInterval(interval)
            let fireHour = cal.component(.hour, from: fireDate)
            if isInQuietHours(hour: fireHour) {
                // Push to wake time.
                if let wakeDate = nextWakeDate(from: now) {
                    let adjusted = wakeDate.timeIntervalSince(now)
                    scheduleNotification(after: max(adjusted, 60))
                }
            } else {
                scheduleNotification(after: interval)
            }
        }
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    // MARK: - Quiet Hours Helpers

    private func isInQuietHours(hour: Int) -> Bool {
        if quietStartHour <= quietEndHour {
            // Doesn't wrap around midnight: e.g., quiet 08–20
            return hour >= quietStartHour && hour < quietEndHour
        } else {
            // Wraps around midnight: e.g., quiet 22–07
            return hour >= quietStartHour || hour < quietEndHour
        }
    }

    private func nextWakeDate(from date: Date) -> Date? {
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: date)
        components.hour = quietEndHour
        components.minute = 0
        components.second = 0

        if let candidate = cal.date(from: components), candidate > date {
            return candidate
        }
        // Wake time already passed today — use tomorrow.
        components.day = (components.day ?? 0) + 1
        return cal.date(from: components)
    }

    // MARK: - Notification Posting

    private func scheduleNotification(after interval: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Flux"
        content.sound = .default

        // Use Roast Mode flag from UserDefaults (set by SettingsView).
        let isRoast = UserDefaults.standard.bool(forKey: "isRoastModeEnabled")
        content.body = isRoast ? roastMessages.randomElement()! : friendlyMessages.randomElement()!

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 60), repeats: false)
        let request = UNNotificationRequest(identifier: "flux_reminder", content: content, trigger: trigger)

        center.add(request) { error in
            if let error {
                print("ReminderScheduler: failed to schedule — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Message Banks

    private let friendlyMessages = [
        "Time for a sip! Your body will thank you. 💧",
        "Keep the flow going, you're doing great!",
        "A little water goes a long way. Stay hydrated! 🌊",
        "Your future self says thanks for drinking water now.",
        "Hydration check! Take a quick sip. 💙",
    ]

    private let roastMessages = [
        "Your kidneys just filed a formal complaint. Drink water now. 🏜️",
        "Are you trying to mummify yourself? Because it's working.",
        "Breaking news: local human forgets how to drink water. More at 11.",
        "Your water bottle is literally crying. Have a sip.",
        "Plot twist: water is free and you're still dehydrated. 💀",
    ]

    private func reschedule() {
        guard reminderEnabled else { return }
        scheduleNext()
    }
}
