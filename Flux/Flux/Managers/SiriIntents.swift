import AppIntents
import Foundation
import SwiftData

/// App Intents make the two most common actions available from Siri and the
/// Shortcuts app without opening the camera or changing measurement behavior.
struct FluxLogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Log water"
    static var description = IntentDescription("Add a drink to your Flux hydration history.")
    static var openAppWhenRun = false

    @Parameter(title: "Amount in milliliters")
    var amountML: Int

    init() {
        amountML = 250
    }

    init(amountML: Int) {
        self.amountML = amountML
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (1...5000).contains(amountML) else {
            return .result(dialog: "Please enter an amount from 1 to 5000 milliliters.")
        }

        let amount = amountML
        let message = try await MainActor.run { () throws -> String in
            let container = try FluxIntentStore.makeContainer()
            let context = container.mainContext
            context.insert(WaterRecord(amountML: amount))
            try context.save()
            return "Logged \(amount) milliliters in Flux."
        }

        return .result(dialog: "\(message)")
    }
}

struct FluxHydrationStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Flux hydration"
    static var description = IntentDescription("Tell me how much water I have logged today in Flux.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await MainActor.run { () throws -> String in
            let container = try FluxIntentStore.makeContainer()
            let context = container.mainContext
            let records = try context.fetch(FetchDescriptor<WaterRecord>())
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let total = records
                .filter { $0.timestamp >= startOfDay }
                .reduce(0) { $0 + $1.amountML }
            let settings = try context.fetch(FetchDescriptor<UserSettings>()).first
            let goal = max(settings?.baseGoalML ?? 2000, 1)
            return "You have logged \(total) milliliters today, \(goal) milliliters is your goal."
        }

        return .result(dialog: "\(message)")
    }
}

private enum FluxIntentStore {
    @MainActor
    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: WaterRecord.self, UserSettings.self, BottleProfile.self)
    }
}

struct FluxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
                intent: FluxLogWaterIntent(),
            phrases: [
                "Log water in \(.applicationName)",
                "Add water in \(.applicationName)",
                "在 \(.applicationName) 記錄飲水",
                "在 \(.applicationName) 新增飲水"
                ],
                shortTitle: "Log water",
                systemImageName: "drop.fill"
        )
        AppShortcut(
                intent: FluxHydrationStatusIntent(),
            phrases: [
                "How much water have I had in \(.applicationName)",
                "Check my hydration in \(.applicationName)",
                "查詢 \(.applicationName) 今日飲水量",
                "查看 \(.applicationName) 飲水進度"
                ],
                shortTitle: "Check hydration",
                systemImageName: "chart.bar.fill"
        )
    }
}
