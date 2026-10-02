import SwiftUI
import SwiftData
import Charts

private struct HydrationDay: Identifiable {
    let date: Date
    let amountML: Int

    var id: Date { date }
    var dayNumber: Int { Calendar.current.component(.day, from: date) }
    var shortLabel: String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }
}

struct AnalyticsView: View {
    @Query private var settingsList: [UserSettings]
    @Query(sort: \WaterRecord.timestamp, order: .reverse) private var waterRecords: [WaterRecord]
    @Environment(\.modelContext) private var modelContext

    private var currentSettings: UserSettings {
        if let first = settingsList.first { return first }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }

    private var dailyGoalML: Int { max(currentSettings.baseGoalML, 1) }
    private var todayTotalML: Int { total(for: Date()) }
    private var todayProgress: Double {
        min(Double(todayTotalML) / Double(dailyGoalML), 1)
    }

    private var currentMonthDays: [HydrationDay] {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        let count = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        return (1...count).compactMap { day in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: start) else { return nil }
            return HydrationDay(date: date, amountML: total(for: date))
        }
    }

    private var lastSevenDays: [HydrationDay] {
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return HydrationDay(date: calendar.startOfDay(for: date), amountML: total(for: date))
        }
    }

    private var recentRecords: [WaterRecord] { Array(waterRecords.prefix(12)) }

    private var csvExport: String {
        let formatter = ISO8601DateFormatter()
        let rows = waterRecords
            .sorted { $0.timestamp < $1.timestamp }
            .map { "\(formatter.string(from: $0.timestamp)),\($0.amountML)" }
        return (["timestamp,amount_ml"] + rows).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        progressCard
                        weeklyTrendCard
                        monthHeatmapCard
                        recentLogCard
                        streakFreezeCard
                    }
                    .padding(.top)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Analytics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: csvExport,
                        subject: Text("Flux hydration data"),
                        message: Text("Exported from Flux")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export hydration history")
                }
            }
        }
    }

    private var progressCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Today", systemImage: "drop.fill")
                    .font(.headline)
                Spacer()
                Text("\(todayTotalML) / \(dailyGoalML) ml")
                    .font(.headline.monospacedDigit())
            }

            ProgressView(value: todayProgress)
                .tint(todayTotalML >= dailyGoalML ? .green : .blue)

            HStack {
                Text("\(Int(todayProgress * 100))% of goal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(waterRecords.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    private var weeklyTrendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last 7 days")
                .font(.headline)

            Chart(lastSevenDays) { day in
                BarMark(
                    x: .value("Day", day.shortLabel),
                    y: .value("Water", day.amountML)
                )
                .foregroundStyle(day.amountML >= dailyGoalML ? Color.green : Color.blue)
                .cornerRadius(5)

                RuleMark(y: .value("Goal", dailyGoalML))
                    .foregroundStyle(.gray.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    private var monthHeatmapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This Month")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                ForEach(currentMonthDays) { day in
                    VStack(spacing: 3) {
                        Text("\(day.dayNumber)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(heatColor(for: day.amountML))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if day.amountML > 0 {
                                    Text("\(day.amountML)")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .minimumScaleFactor(0.5)
                                }
                            }
                    }
                }
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    private var recentLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent entries")
                    .font(.headline)
                Spacer()
                ShareLink(item: csvExport) {
                    Label("Export CSV", systemImage: "doc.text")
                        .font(.caption.bold())
                }
            }

            if recentRecords.isEmpty {
                Text("No hydration entries yet. Use Quick Add or scan your bottle.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentRecords) { record in
                    HStack {
                        Image(systemName: "drop")
                            .foregroundStyle(.blue)
                        Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                        Spacer()
                        Text("+\(record.amountML) ml")
                            .font(.subheadline.bold().monospacedDigit())
                        Button(role: .destructive) {
                            modelContext.delete(record)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete entry")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    private var streakFreezeCard: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Streak Freeze")
                    .font(.headline)
                Text("Tokens: \(currentSettings.streakFreezeTokens) 💧")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            Button {
                currentSettings.streakFreezeTokens += 1
            } label: {
                Text("Get (10 💧)")
                    .font(.subheadline).bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    private func total(for date: Date) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return waterRecords
            .filter { $0.timestamp >= start && $0.timestamp < end }
            .reduce(0) { $0 + $1.amountML }
    }

    private func heatColor(for amount: Int) -> Color {
        guard amount > 0 else { return .blue.opacity(0.08) }
        let ratio = min(Double(amount) / Double(dailyGoalML), 1)
        return Color.blue.opacity(0.2 + ratio * 0.75)
    }
}
