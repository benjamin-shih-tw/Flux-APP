import Foundation
import UserNotifications

@Observable
final class NotificationManager {
    private let center = UNUserNotificationCenter.current()
    private let reminderPrefix = "flux.hydration."
    var isAuthorized = false

    private let friendlyMessages = [
        "Time for a sip! Your body will thank you. 💧",
        "Keep the flow going, you're doing great!",
        "Don't forget to hydrate today!"
    ]

    private let roastMessages = [
        "Your water sprite misses you. Have a sip. 💧",
        "Your bottle is waiting. Take a water break."
    ]

    func requestAuthorization() async {
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            isAuthorized = false
            print("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func scheduleSmartReminders(records: [WaterRecord], goalML: Int, intervalHours: Int, isRoastMode: Bool) async {
        await refreshAuthorization()
        guard isAuthorized else { return }

        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(reminderPrefix) })

        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let todayRecords = records.filter { $0.timestamp >= today }
        let reachedGoal = todayRecords.reduce(0) { $0 + $1.amountML } >= goalML
        let lastDrink = todayRecords.map(\.timestamp).max()
        let spacing = max(1, min(intervalHours, 4))

        for dayOffset in 0..<4 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            if dayOffset == 0 && reachedGoal { continue }
            for hour in stride(from: 9, through: 21, by: spacing) {
                guard let fireDate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), fireDate > now else { continue }
                if dayOffset == 0, let lastDrink,
                   fireDate.timeIntervalSince(lastDrink) < Double(spacing) * 3600 { continue }

                let content = UNMutableNotificationContent()
                content.title = "Flux"
                let messages = isRoastMode ? roastMessages : friendlyMessages
                content.body = messages[hour % messages.count]
                content.sound = .default
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let request = UNNotificationRequest(
                    identifier: "\(reminderPrefix)\(dayOffset).\(hour)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
                do { try await center.add(request) }
                catch { print("Reminder scheduling failed: \(error.localizedDescription)") }
            }
        }
    }

    func cancelReminders() async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(reminderPrefix) })
    }
}
