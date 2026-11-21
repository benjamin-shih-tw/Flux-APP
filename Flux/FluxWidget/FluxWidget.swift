import SwiftUI
import WidgetKit

private struct HydrationEntry: TimelineEntry {
    let date: Date
    let totalML: Int
    let goalML: Int
}

private struct HydrationProvider: TimelineProvider {
    func placeholder(in context: Context) -> HydrationEntry {
        HydrationEntry(date: Date(), totalML: 1250, goalML: 2000)
    }

    func getSnapshot(in context: Context, completion: @escaping (HydrationEntry) -> Void) {
        completion(entry(for: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HydrationEntry>) -> Void) {
        let now = Date()
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(86400)
        completion(Timeline(entries: [entry(for: now), entry(for: midnight)], policy: .after(midnight.addingTimeInterval(60))))
    }

    private func entry(for date: Date) -> HydrationEntry {
        let defaults = UserDefaults(suiteName: "group.benjaminshih.Flux")
        let storedDay = defaults?.double(forKey: "day") ?? 0
        let isToday = storedDay == Calendar.current.startOfDay(for: date).timeIntervalSince1970
        return HydrationEntry(
            date: date,
            totalML: isToday ? defaults?.integer(forKey: "total_ml") ?? 0 : 0,
            goalML: max(defaults?.integer(forKey: "goal_ml") ?? 2000, 1)
        )
    }
}

private struct HydrationWidgetView: View {
    let entry: HydrationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "drop.fill")
                .font(.system(size: family == .systemSmall ? 30 : 36))
                .foregroundStyle(Color(red: 0.35, green: 0.76, blue: 1))
            VStack(alignment: .leading, spacing: 7) {
                Text("Flux")
                    .font(.headline)
                Text("\(entry.totalML.formatted()) ml")
                    .font(.title2.bold().monospacedDigit())
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                ProgressView(value: min(Double(entry.totalML) / Double(entry.goalML), 1))
                    .tint(Color(red: 0.35, green: 0.76, blue: 1))
                Text("Goal \(entry.goalML.formatted()) ml")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .containerBackground(Color(red: 0.10, green: 0.11, blue: 0.13), for: .widget)
    }
}

@main
struct FluxWidget: Widget {
    let kind = "FluxHydrationWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HydrationProvider()) { entry in
            HydrationWidgetView(entry: entry)
        }
        .configurationDisplayName("Flux Hydration")
        .description("Today's water intake and daily goal.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
