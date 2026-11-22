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
    @Environment(HealthKitManager.self) private var healthManager
    @State private var showsSevenDayAverage = false
    @State private var showsHistory = false
    @State private var monthOffset = 0

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
        let month = calendar.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
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

    /// A live streak is counted from the most recently completed goal day.
    /// This keeps the streak useful during the day: an unfinished today does
    /// not erase yesterday's completed streak, but a missed day does.
    private var currentGoalStreak: Int {
        let calendar = Calendar.current
        var cursor = calendar.startOfDay(for: Date())

        if total(for: cursor) < dailyGoalML {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                return 0
            }
            cursor = yesterday
        }

        var streak = 0
        while total(for: cursor) >= dailyGoalML {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return streak
    }

    private var longestGoalStreak: Int {
        let calendar = Calendar.current
        let totalsByDay = Dictionary(grouping: waterRecords) {
            calendar.startOfDay(for: $0.timestamp)
        }
        .mapValues { records in records.reduce(0) { $0 + $1.amountML } }

        var longest = 0
        var running = 0
        var previousDay: Date?

        for day in totalsByDay.keys.sorted() {
            let isConsecutive = previousDay.map {
                calendar.dateComponents([.day], from: $0, to: day).day == 1
            } ?? false

            if isConsecutive && (totalsByDay[day] ?? 0) >= dailyGoalML {
                running += 1
            } else {
                running = (totalsByDay[day] ?? 0) >= dailyGoalML ? 1 : 0
            }

            longest = max(longest, running)
            previousDay = day
        }
        return longest
    }

    private var daysMetThisMonth: Int {
        currentMonthDays.filter { $0.amountML >= dailyGoalML }.count
    }

    /// A bounded 7-day score: it rewards both meeting the goal and doing so
    /// consistently, while never exceeding 100%.
    private var sevenDayConsistency: Int {
        let score = lastSevenDays.reduce(0.0) { partial, day in
            partial + min(Double(day.amountML) / Double(dailyGoalML), 1.0)
        } / 7.0
        return Int((score * 100).rounded())
    }

    private var sevenDayAverageML: Int {
        lastSevenDays.reduce(0) { $0 + $1.amountML } / 7
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
            ScrollView {
                VStack(spacing: 10) {
                    HStack {
                        Text("Streak")
                            .font(.geist(size: 28, relativeTo: .largeTitle, weight: .bold))
                        Spacer()
                        Button { showsHistory = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 18))
                                .frame(width: 38, height: 38)
                        }
                        .accessibilityLabel("Recent entries and export")
                    }
                    .padding(.bottom, 2)
                    HStack(spacing: 3) {
                        segmentButton("Today", selected: !showsSevenDayAverage) { showsSevenDayAverage = false }
                        segmentButton("7-day trend", selected: showsSevenDayAverage) { showsSevenDayAverage = true }
                    }
                    .padding(3)
                    .background(FluxTheme.surface, in: Capsule())
                    weeklyTrendCard
                    statsDuo
                    monthHeatmapCard
                    streakInsightsCard
                    achievementsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(FluxTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showsHistory) {
                NavigationStack {
                    ScrollView { recentLogCard.padding() }
                        .background(FluxTheme.background)
                        .navigationTitle("Recent entries")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showsHistory = false }
                            }
                        }
                }
            }
        }
    }

    private func segmentButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.geist(size: 13, relativeTo: .subheadline, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 31)
                .background(selected ? FluxTheme.elevated : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var weeklyTrendCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\((showsSevenDayAverage ? sevenDayAverageML : todayTotalML).formatted()) ml")
                        .font(.geist(size: 20, relativeTo: .title2, weight: .bold).monospacedDigit())
                    Text(showsSevenDayAverage ? "7-day average" : "of \(dailyGoalML.formatted()) ml")
                        .font(.geist(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(showsSevenDayAverage ? sevenDayConsistency : Int(todayProgress * 100))%")
                    .font(.geist(size: 16, relativeTo: .headline, weight: .semibold).monospacedDigit())
            }

            Chart {
                ForEach(lastSevenDays) { day in
                    AreaMark(
                        x: .value("Day", day.shortLabel),
                        y: .value("Water", day.amountML)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [FluxTheme.accent.opacity(0.3), FluxTheme.accent.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Day", day.shortLabel),
                        y: .value("Water", day.amountML)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(FluxTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))

                    PointMark(
                        x: .value("Day", day.shortLabel),
                        y: .value("Water", day.amountML)
                    )
                    .foregroundStyle(FluxTheme.accent)
                    .symbolSize(38)
                }

                RuleMark(y: .value("Goal", dailyGoalML))
                    .foregroundStyle(.white.opacity(0.16))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartYScale(domain: 0...(Double(max(dailyGoalML, lastSevenDays.map(\.amountML).max() ?? 0, 1)) * 1.15))
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .frame(height: 76)

            HStack {
                ForEach(lastSevenDays) { day in
                    Text(day.shortLabel)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.geist(size: 11, relativeTo: .caption2))
            .foregroundStyle(FluxTheme.muted)
        }
        .padding(15)
        .fluxCard()
    }

    private var statsDuo: some View {
        HStack(spacing: 10) {
            statCard("flame.fill", value: "\(currentGoalStreak) days", caption: "streak")
            statCard("target", value: "\(sevenDayConsistency)%", caption: "7-day avg.")
        }
    }

    private func statCard(_ symbol: String, value: String, caption: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.geist(size: 16, relativeTo: .headline, weight: .bold))
                Text(caption).font(.geist(size: 12, relativeTo: .caption)).foregroundStyle(FluxTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .fluxCard(cornerRadius: 18)
    }

    private var monthHeatmapCard: some View {
        let firstDay = currentMonthDays.first?.date ?? Date()

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Monthly Progress")
                    .font(.geist(size: 13.5, relativeTo: .subheadline, weight: .semibold))
                Spacer()
                Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                Text(firstDay.formatted(.dateTime.month(.abbreviated)))
                    .foregroundStyle(FluxTheme.accent)
                Button { monthOffset = min(monthOffset + 1, 0) } label: { Image(systemName: "chevron.right") }
                    .disabled(monthOffset == 0)
            }
            .font(.geist(size: 12, relativeTo: .caption, weight: .semibold))
            .buttonStyle(.plain)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 11), spacing: 5) {
                ForEach(currentMonthDays) { day in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(heatColor(for: day.amountML))
                        .frame(height: 15)
                        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.amountML) milliliters")
                }
            }
            Text("\(daysMetThisMonth) goal days this month")
                .font(.geist(size: 11, relativeTo: .caption2))
                .foregroundStyle(FluxTheme.muted)
        }
        .padding(14)
        .fluxCard()
    }

    private var streakInsightsCard: some View {
        HStack(spacing: 11) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text("Habit Insights")
                    .font(.geist(size: 13.5, relativeTo: .subheadline, weight: .semibold))
                Text("\(daysMetThisMonth) goal days this month · best streak \(longestGoalStreak) days")
                    .font(.geist(size: 12, relativeTo: .caption))
                    .foregroundStyle(FluxTheme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(FluxTheme.muted)
        }
        .padding(14)
        .fluxCard(cornerRadius: 18)
    }

    private var achievementsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Achievements")
                    .font(.geist(size: 13.5, relativeTo: .subheadline, weight: .semibold))
                Spacer()
                Text("\(min(1 + (currentGoalStreak >= 7 ? 1 : 0) + (daysMetThisMonth >= 15 ? 1 : 0), 3)) / 8")
                    .font(.geist(size: 12, relativeTo: .caption, weight: .semibold))
                    .foregroundStyle(FluxTheme.accent)
            }
            HStack {
                achievement("drop.fill", unlocked: !waterRecords.isEmpty)
                Spacer()
                achievement("calendar", unlocked: currentGoalStreak >= 7)
                Spacer()
                achievement("leaf.fill", unlocked: daysMetThisMonth >= 15)
                Spacer()
                achievement("lock.fill", unlocked: false)
            }
        }
        .padding(14)
        .fluxCard(cornerRadius: 20)
    }

    private func achievement(_ symbol: String, unlocked: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(unlocked ? FluxTheme.accent : FluxTheme.muted.opacity(0.55))
            .frame(width: 51, height: 51)
            .background(unlocked ? FluxTheme.accent.opacity(0.12) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(unlocked ? FluxTheme.accent.opacity(0.55) : .white.opacity(0.1), lineWidth: 1) }
    }

    private var recentLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent entries")
                    .font(.geist(.headline))
                Spacer()
                ShareLink(item: csvExport) {
                    Label("Export CSV", systemImage: "doc.text")
                        .font(.geist(.caption, weight: .bold))
                }
            }

            if recentRecords.isEmpty {
                Text("No hydration entries yet. Use Quick Add or scan your bottle.")
                    .font(.geist(.subheadline))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentRecords) { record in
                    HStack {
                        Image(systemName: "drop")
                            .foregroundStyle(FluxTheme.accent)
                        Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.geist(.subheadline))
                        Spacer()
                        Text("+\(record.amountML) ml")
                            .font(.geist(.subheadline, weight: .bold).monospacedDigit())
                        Button(role: .destructive) {
                            let deletedID = record.id
                            modelContext.delete(record)
                            Task { await healthManager.deleteWaterRecord(id: deletedID) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.geist(.caption))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete entry")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .fluxCard(cornerRadius: 20)
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
        guard amount > 0 else { return FluxTheme.accent.opacity(0.08) }
        let ratio = min(Double(amount) / Double(dailyGoalML), 1)
        return FluxTheme.accent.opacity(0.2 + ratio * 0.75)
    }
}
