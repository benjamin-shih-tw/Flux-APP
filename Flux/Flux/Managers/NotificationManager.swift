import Foundation
import UserNotifications
import SwiftUI

@Observable
final class NotificationManager {
    let center = UNUserNotificationCenter.current()
    var isAuthorized = false
    
    let friendlyMessages = [
        "Time for a sip! Your body will thank you. 💧",
        "Keep the flow going, you're doing great!",
        "Don't forget to hydrate today!"
    ]
    
    let roastMessages = [
        "Your kidneys just filed a formal complaint. Drink water now. 🏜️",
        "Are you trying to mummify yourself? Because it's working.",
        "Your water sprite is literally writing its will. Have a sip.",
        "Breaking news: local human forgets how to drink water. More at 11."
    ]
    
    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            DispatchQueue.main.async {
                self.isAuthorized = granted
            }
        } catch {
            print("Notification auth error: \(error.localizedDescription)")
        }
    }
    
    // Bug Prevention: Clear existing pending notifications before scheduling new ones to avoid spam
    func scheduleReminder(isRoastMode: Bool, delayTimeInterval: TimeInterval = 7200) {
        guard isAuthorized else { return }
        
        center.removeAllPendingNotificationRequests()
        
        let content = UNMutableNotificationContent()
        content.title = "Flux"
        content.body = isRoastMode ? roastMessages.randomElement()! : friendlyMessages.randomElement()!
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delayTimeInterval, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        center.add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }
}
