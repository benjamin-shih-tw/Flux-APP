import SwiftUI
import SwiftData
import UIKit

struct DashboardView: View {
    @Environment(DynamicGoalEngine.self) private var goalEngine
    @Environment(HealthKitManager.self) private var healthManager
    @Environment(WeatherKitManager.self) private var weatherManager
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    @Query private var settingsList: [UserSettings]
    @Query(sort: \WaterRecord.timestamp, order: .reverse) private var waterRecords: [WaterRecord]
    @Query(filter: #Predicate<BottleProfile> { $0.isDefault == true }) private var defaultBottles: [BottleProfile]

    @State private var waterTrigger: Int = 0
    @State private var showBottleSetup = false
    @State private var showCustomWaterEntry = false
    @State private var showReminderInfo = false

    private var currentSettings: UserSettings {
        if let first = settingsList.first { return first }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }

    private var todayIntake: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return waterRecords
            .filter { $0.timestamp >= startOfDay }
            .reduce(0) { $0 + $1.amountML }
    }

    private var dynamicDailyGoal: Int {
        let base = Double(currentSettings.baseGoalML)
        goalEngine.baseGoalML = base
        return goalEngine.calculateTodayGoal(
            activeEnergyKCal: healthManager.todayActiveEnergyBurned,
            apparentTempCelsius: weatherManager.currentApparentTemperature
        )
    }

    private var todayProgress: Double {
        min(Double(todayIntake) / Double(max(dynamicDailyGoal, 1)), 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        (Text("Flux") + Text(".").foregroundColor(FluxTheme.accent))
                            .font(.geist(size: 31, relativeTo: .largeTitle, weight: .bold))
                        Spacer()
                        Button { showReminderInfo = true } label: {
                            Image(systemName: "bell")
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 38, height: 38)
                                .fluxCard(cornerRadius: 19)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hydration reminders")
                    }
                    .padding(.bottom, 2)
                    hydrationCard
                    bottleCard
                    ForestProgressView(
                        todayIntake: todayIntake,
                        dailyGoal: dynamicDailyGoal,
                        waterTrigger: waterTrigger
                    )
                    quickAddSection
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(FluxTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task { weatherManager.requestLocationAndWeather() }
            .fullScreenCover(isPresented: $showBottleSetup) {
                BottleProfileScannerView()
            }
            .sheet(isPresented: $showCustomWaterEntry) {
                CustomWaterEntryView { amount in addWater(amount) }
                    .presentationDetents([.height(280)])
            }
            .alert("Hydration reminders", isPresented: $showReminderInfo) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("You can adjust reminders in Settings.")
            }
        }
    }

    private var hydrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today's hydration")
                .font(.geist(size: 13, relativeTo: .subheadline, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(todayIntake.formatted())
                    .font(.geist(size: 38, relativeTo: .largeTitle, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText())
                Text("/ \(dynamicDailyGoal.formatted()) ml")
                    .font(.geist(size: 18, relativeTo: .title3, weight: .medium))
                    .foregroundStyle(FluxTheme.muted)
                Spacer(minLength: 0)
            }

            GeometryReader { geometry in
                Capsule()
                    .fill(Color(red: 0.24, green: 0.26, blue: 0.29))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(LinearGradient(colors: [Color(red: 0.61, green: 0.89, blue: 1), FluxTheme.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geometry.size.width * todayProgress))
                            .shadow(color: FluxTheme.accent.opacity(0.5), radius: 8)
                    }
            }
            .frame(height: 14)

            HStack {
                Text("\(Int(todayProgress * 100))% completed")
                Spacer()
                Text(todayIntake >= dynamicDailyGoal
                     ? "Goal reached"
                     : "\(dynamicDailyGoal - todayIntake) ml to go")
            }
            .font(.geist(size: 12.5, relativeTo: .caption, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.84))

            if healthManager.todayActiveEnergyBurned > 100 ||
                (weatherManager.currentApparentTemperature ?? 0) > 28 {
                HStack(spacing: 12) {
                    if healthManager.todayActiveEnergyBurned > 100 {
                        Label("Workout adjusted", systemImage: "figure.run")
                    }
                    if (weatherManager.currentApparentTemperature ?? 0) > 28 {
                        Label("Heat adjusted", systemImage: "sun.max")
                    }
                }
                .font(.geist(.caption2, weight: .medium))
                .foregroundStyle(FluxTheme.accent)
            }
        }
        .padding(17)
        .fluxCard()
    }

    private var bottleCard: some View {
        let bottle = defaultBottles.first
        let hasModel = bottle.map { $0.profilePoints.count >= 2 } ?? false
        let hasScan = hasModel && currentSettings.lastScanTimestamp != nil

        return HStack(spacing: 14) {
            DashboardBottle3DView(
                fillFraction: hasScan ? currentSettings.bottleFillFraction : (hasModel ? 0 : 0.42),
                customProfile: hasModel ? bottle?.profilePoints : nil,
                multiAngleProfiles: hasModel ? bottle?.multiAngleProfiles : nil
            )
            .frame(width: 130, height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .allowsHitTesting(hasModel)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(hasModel ? (bottle?.name ?? "My Bottle") : "My Bottle")
                    .font(.geist(.headline))
                    .lineLimit(1)
                Text(hasModel ? "\(Int(bottle?.totalVolumeMl ?? 0).formatted()) ml" : "Preview · add a bottle")
                    .font(.geist(.caption))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if hasScan {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(currentSettings.lastScanRemainingML)) ml")
                            .font(.geist(size: 25, relativeTo: .title2, weight: .bold).monospacedDigit())
                            .foregroundStyle(FluxTheme.accent)
                        Text("remaining")
                            .font(.geist(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(FluxTheme.elevated, in: RoundedRectangle(cornerRadius: 13))
                } else if hasModel {
                    Label("Ready to scan", systemImage: "checkmark.circle")
                        .font(.geist(.caption, weight: .medium))
                        .foregroundStyle(FluxTheme.accent)
                } else {
                    Button {
                        showBottleSetup = true
                    } label: {
                        Label("Set up bottle", systemImage: "plus")
                            .font(.geist(.caption, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .frame(height: 198)
        .fluxCard()
    }

    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quick Add")
                    .font(.geist(.subheadline, weight: .semibold))
                Spacer()
                Button { showCustomWaterEntry = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 18))
                }
                .accessibilityLabel("Custom amount")
            }

            HStack(spacing: 8) {
                QuickAddButton(amount: 100, action: { addWater(100) })
                QuickAddButton(amount: 250, action: { addWater(250) })
                QuickAddButton(amount: 500, action: { addWater(500) })
            }
        }
    }

    private func addWater(_ amount: Int) {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        withAnimation {
            let record = WaterRecord(amountML: amount)
            modelContext.insert(record)
        }
        let todayTotal = todayIntake + amount
        watchManager.sendWaterAdded(
            amountML: amount,
            todayTotalML: todayTotal,
            goalML: dynamicDailyGoal
        )
        // Trigger raindrop animation in forest
        waterTrigger += 1
    }
}

private struct CustomWaterEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    let onSave: (Int) -> Void

    private var parsedAmount: Int? {
        guard let value = Int(amountText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...5000).contains(value) else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount in ml", text: $amountText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Enter a value from 1 to 5000 ml.")
                }
            }
            .navigationTitle("Add water")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let amount = parsedAmount else { return }
                        onSave(amount)
                        dismiss()
                    }
                    .disabled(parsedAmount == nil)
                }
            }
        }
    }
}

struct QuickAddButton: View {
    let amount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("+\(amount) ml")
                .font(.geist(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .fluxCard(cornerRadius: 15)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(amount) milliliters")
    }
}
