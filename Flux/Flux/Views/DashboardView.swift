import SwiftUI
import SwiftData
import UIKit

struct DashboardView: View {
    @Environment(DynamicGoalEngine.self) private var goalEngine
    @Environment(HealthKitManager.self) private var healthManager
    @Environment(WeatherKitManager.self) private var weatherManager
    @Environment(ReminderScheduler.self) private var reminderScheduler
    @Environment(\.modelContext) private var modelContext

    @Query private var settingsList: [UserSettings]
    @Query(sort: \WaterRecord.timestamp, order: .reverse) private var waterRecords: [WaterRecord]
    @Query(filter: #Predicate<BottleProfile> { $0.isDefault == true }) private var defaultBottles: [BottleProfile]

    @State private var waterTrigger: Int = 0
    @State private var showBottleSetup = false

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

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {

                        // MARK: Context Badges
                        HStack(spacing: 8) {
                            if healthManager.todayActiveEnergyBurned > 100 {
                                Label("Workout Bonus", systemImage: "figure.run")
                                    .font(.caption).bold()
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
                                    .clipShape(Capsule())
                            }
                            if let temp = weatherManager.currentApparentTemperature, temp > 28 {
                                Label("Heat Bonus", systemImage: "thermometer.sun.fill")
                                    .font(.caption).bold()
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.1))
                                    .foregroundColor(.orange)
                                    .clipShape(Capsule())
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                        .frame(height: 30)

                        // MARK: Forest Progress Card
                        ForestProgressView(
                            todayIntake: todayIntake,
                            dailyGoal: dynamicDailyGoal,
                            waterTrigger: waterTrigger
                        )
                        .padding(.horizontal)

                        // MARK: Inline 3D Bottle
                        VStack(spacing: 8) {
                            Text("Your Bottle")
                                .font(.subheadline).bold()
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)

                            if let bottle = defaultBottles.first, bottle.profilePoints.count >= 2 {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(Color.white)
                                        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)

                                    VStack(spacing: 0) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(bottle.name)
                                                    .font(.caption).bold()
                                                if currentSettings.lastScanTimestamp != nil {
                                                    Text("\(Int(currentSettings.lastScanRemainingML)) ml remaining")
                                                        .font(.caption2)
                                                        .foregroundColor(.blue)
                                                } else {
                                                    Text("3D model ready · scan water level next")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "hand.draw")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding([.top, .horizontal], 16)

                                        DashboardBottle3DView(
                                            fillFraction: currentSettings.lastScanTimestamp == nil ? 1 : currentSettings.bottleFillFraction,
                                            customProfile: bottle.profilePoints,
                                            multiAngleProfiles: bottle.multiAngleProfiles,
                                            bottleColor: UIColor(
                                                red: CGFloat(bottle.modelColorRed),
                                                green: CGFloat(bottle.modelColorGreen),
                                                blue: CGFloat(bottle.modelColorBlue),
                                                alpha: 1
                                            )
                                        )
                                        .frame(height: 200)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                    }
                                }
                                .padding(.horizontal)
                            } else {
                                Button {
                                    showBottleSetup = true
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "cube.transparent")
                                            .font(.system(size: 28))
                                            .foregroundColor(.blue)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Create your bottle model")
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            Text("Scan it once to add a 3D model here")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 20))
                                    .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal)
                            }
                        }

                        // MARK: Quick Add Buttons
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Quick Add")
                                .font(.subheadline).bold()
                                .foregroundColor(.gray)
                                .padding(.horizontal)

                            HStack(spacing: 14) {
                                QuickAddButton(amount: 100,  action: { addWater(100)  })
                                QuickAddButton(amount: 250,  action: { addWater(250)  })
                                QuickAddButton(amount: 500,  action: { addWater(500)  })
                            }
                            .padding(.horizontal)
                        }

                        Spacer(minLength: 30)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Flux")
            .task {
                weatherManager.requestLocationAndWeather()
            }
            .fullScreenCover(isPresented: $showBottleSetup) {
                BottleProfileScannerView()
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
        // Trigger raindrop animation in forest
        waterTrigger += 1

        // Streak check
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let newTodayIntake = waterRecords
            .filter { $0.timestamp >= startOfToday }
            .reduce(0) { $0 + $1.amountML } + amount
        let yesterdayIntake = waterRecords
            .filter { $0.timestamp >= startOfYesterday && $0.timestamp < startOfToday }
            .reduce(0) { $0 + $1.amountML }
        currentSettings.updateStreak(todayIntake: newTodayIntake, yesterdayIntake: yesterdayIntake)

        // Sync to HealthKit
        Task { await healthManager.saveWaterIntake(amountML: amount) }

        // Reset reminder countdown
        reminderScheduler.userDidLogWater()
    }
}

struct QuickAddButton: View {
    let amount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                Text("\(amount)ml")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)
        }
    }
}
