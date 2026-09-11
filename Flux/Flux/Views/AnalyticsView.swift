import SwiftUI
import SwiftData
import Charts

// MARK: - Chart Data Types

private struct DailyIntake: Identifiable {
    let id = UUID()
    let date: Date
    let intake: Int
    let goal: Int

    var isGoalMet: Bool { intake >= goal }
}

private struct HourlyIntake: Identifiable {
    let id = UUID()
    let hour: Int
    let intake: Int
}

// MARK: - Analytics View

struct AnalyticsView: View {
    @Query private var settingsList: [UserSettings]
    @Query(sort: \WaterRecord.timestamp, order: .reverse) private var allRecords: [WaterRecord]
    @Environment(\.modelContext) private var modelContext

    private var currentSettings: UserSettings {
        if let first = settingsList.first { return first }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }

    private var dailyGoal: Int { currentSettings.baseGoalML }

    // MARK: - Data Computation

    private func intake(for date: Date) -> Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return allRecords
            .filter { $0.timestamp >= start && $0.timestamp < end }
            .reduce(0) { $0 + $1.amountML }
    }

    /// Past 7 days in chronological order (oldest first).
    private var last7Days: [DailyIntake] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: today)!
            return DailyIntake(date: date, intake: intake(for: date), goal: dailyGoal)
        }
    }

    private var weeklyAverage: Int {
        last7Days.reduce(0) { $0 + $1.intake } / 7
    }

    /// Intake per day of the current month, keyed by day-of-month (1-indexed).
    private var monthIntakeByDay: [Int: Int] {
        let cal = Calendar.current
        let today = Date()
        let components = cal.dateComponents([.year, .month], from: today)
        var result: [Int: Int] = [:]
        for record in allRecords {
            let rc = cal.dateComponents([.year, .month, .day], from: record.timestamp)
            if rc.year == components.year && rc.month == components.month, let day = rc.day {
                result[day, default: 0] += record.amountML
            }
        }
        return result
    }

    private var daysGoalMetThisMonth: Int {
        monthIntakeByDay.values.filter { $0 >= dailyGoal }.count
    }

    private var monthlyAverage: Int {
        let activeDays = monthIntakeByDay.values.filter { $0 > 0 }
        guard !activeDays.isEmpty else { return 0 }
        return activeDays.reduce(0, +) / activeDays.count
    }

    private var todayHourlyData: [HourlyIntake] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayRecords = allRecords.filter { $0.timestamp >= today }

        var hourly = Array(repeating: 0, count: 24)
        for record in todayRecords {
            let hour = cal.component(.hour, from: record.timestamp)
            hourly[hour] += record.amountML
        }
        return hourly.enumerated().map { HourlyIntake(hour: $0.offset, intake: $0.element) }
    }

    private var bestDayRecord: (date: Date, intake: Int)? {
        let cal = Calendar.current
        var dailyTotals: [Date: Int] = [:]
        for record in allRecords {
            let day = cal.startOfDay(for: record.timestamp)
            dailyTotals[day, default: 0] += record.amountML
        }
        return dailyTotals.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }

    private var bestDayDateString: String {
        guard let best = bestDayRecord else { return "" }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: best.date)
    }

    private var totalRecordedDays: Int {
        let cal = Calendar.current
        return Set(allRecords.map { cal.startOfDay(for: $0.timestamp) }).count
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        streakCard
                        weeklyChartCard
                        monthlyHeatmapCard
                        hourlyDistributionCard
                        statisticsCard
                        streakFreezeCard
                    }
                    .padding(.top)
                }
            }
            .navigationTitle("Analytics")
        }
    }

    // MARK: - Streak Card

    private var streakCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("\(currentSettings.currentStreak) Days")
                .font(.system(size: 32, weight: .black, design: .rounded))
            Text("Current Streak")
                .font(.subheadline)
                .foregroundColor(.gray)
            if currentSettings.longestStreak > 0 {
                Text("Best: \(currentSettings.longestStreak) days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    // MARK: - Weekly Bar Chart

    private var weeklyChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This Week")
                    .font(.headline)
                Spacer()
                Text("Avg \(weeklyAverage) ml")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Chart {
                ForEach(last7Days) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Intake", day.intake)
                    )
                    .foregroundStyle(day.isGoalMet ? Color.blue : Color.blue.opacity(0.4))
                    .cornerRadius(6)
                }

                RuleMark(y: .value("Goal", dailyGoal))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .foregroundStyle(Color.orange.opacity(0.6))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Goal")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 180)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    // MARK: - Monthly Heatmap

    private var monthlyHeatmapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(currentMonthName)
                    .font(.headline)
                Spacer()
                Text("\(daysGoalMetThisMonth) days on target")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            let cal = Calendar.current
            let today = Date()
            let daysInMonth = cal.range(of: .day, in: .month, for: today)?.count ?? 30
            let firstWeekdayOffset = firstWeekdayOfCurrentMonth

            // Weekday headers
            HStack(spacing: 8) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { d in
                    Text(d)
                        .font(.caption2).bold()
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                // Empty cells for alignment
                ForEach(0..<firstWeekdayOffset, id: \.self) { _ in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }

                // Day cells
                ForEach(1...daysInMonth, id: \.self) { day in
                    let dayIntake = monthIntakeByDay[day] ?? 0
                    let todayDay = cal.component(.day, from: today)
                    let isFuture = day > todayDay

                    RoundedRectangle(cornerRadius: 6)
                        .fill(heatmapColor(intake: dayIntake, goal: dailyGoal, isFuture: isFuture))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            Text("\(day)")
                                .font(.system(size: 10))
                                .foregroundColor(
                                    isFuture ? .secondary.opacity(0.3)
                                    : (dayIntake >= dailyGoal ? .white : .primary.opacity(0.6))
                                )
                        )
                }
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    private var currentMonthName: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f.string(from: Date())
    }

    private var firstWeekdayOfCurrentMonth: Int {
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month], from: Date())
        components.day = 1
        guard let firstDay = cal.date(from: components) else { return 0 }
        // .weekday: 1 = Sunday. Convert to 0-indexed offset for a Sunday-start grid.
        return cal.component(.weekday, from: firstDay) - 1
    }

    private func heatmapColor(intake: Int, goal: Int, isFuture: Bool) -> Color {
        if isFuture { return Color.gray.opacity(0.06) }
        if intake == 0 { return Color.blue.opacity(0.06) }
        let ratio = Double(intake) / Double(max(goal, 1))
        if ratio >= 1.0 { return Color.blue }
        return Color.blue.opacity(0.15 + min(ratio, 1.0) * 0.45)
    }

    // MARK: - Hourly Distribution

    private var hourlyDistributionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's Timeline")
                .font(.headline)

            let hasData = todayHourlyData.contains { $0.intake > 0 }

            if !hasData {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("No records yet today")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 30)
                    Spacer()
                }
            } else {
                Chart(todayHourlyData) { item in
                    BarMark(
                        x: .value("Hour", item.hour),
                        y: .value("ml", item.intake)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.5), .blue],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let h = value.as(Int.self) {
                                Text(String(format: "%02d:00", h))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXScale(domain: 0...23)
                .frame(height: 120)
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    // MARK: - Statistics Summary

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statTile(
                    title: "Weekly Avg",
                    value: "\(weeklyAverage) ml",
                    icon: "chart.bar.fill",
                    color: .blue
                )
                statTile(
                    title: "Monthly Avg",
                    value: "\(monthlyAverage) ml",
                    icon: "calendar",
                    color: .purple
                )
                statTile(
                    title: "Best Day",
                    value: bestDayRecord.map { "\($0.intake) ml" } ?? "—",
                    subtitle: bestDayDateString.isEmpty ? nil : bestDayDateString,
                    icon: "trophy.fill",
                    color: .orange
                )
                statTile(
                    title: "Tracked Days",
                    value: "\(totalRecordedDays)",
                    icon: "checkmark.circle.fill",
                    color: .green
                )
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal)
    }

    private func statTile(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        color: Color
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            if let sub = subtitle {
                Text(sub)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.08))
        .cornerRadius(14)
    }

    // MARK: - Streak Freeze Store

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
            Button(action: {
                currentSettings.streakFreezeTokens += 1
            }) {
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
}
