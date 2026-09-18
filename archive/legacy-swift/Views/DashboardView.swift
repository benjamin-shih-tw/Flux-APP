import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(DynamicGoalEngine.self) private var goalEngine
    @Environment(HealthKitManager.self) private var healthManager
    @Environment(WeatherKitManager.self) private var weatherManager
    @Environment(\.modelContext) private var modelContext
    
    @Query private var settingsList: [UserSettings]
    @Query(sort: \WaterRecord.timestamp, order: .reverse) private var waterRecords: [WaterRecord]
    
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
        goalEngine.baseGoalML = base // Sync base goal
        return goalEngine.calculateTodayGoal(
            activeEnergyKCal: healthManager.todayActiveEnergyBurned,
            apparentTempCelsius: weatherManager.currentApparentTemperature
        )
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.white.ignoresSafeArea()
                
                VStack(spacing: 40) {
                    // Context Badges
                    HStack {
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
                    }
                    .frame(height: 30)
                    
                    // Main Progress Ring
                    ZStack {
                        Circle()
                            .stroke(Color.blue.opacity(0.1), lineWidth: 20)
                        
                        let progress = min(CGFloat(todayIntake) / CGFloat(max(1, dynamicDailyGoal)), 1.0)
                        Circle()
                            .trim(from: 0.0, to: progress)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(), value: progress)
                        
                        VStack(spacing: 8) {
                            Image(systemName: "drop.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.blue)
                            Text("\(todayIntake)")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .contentTransition(.numericText())
                            Text("/ \(dynamicDailyGoal) ml")
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                                .foregroundColor(.gray)
                        }
                    }
                    .frame(width: 250, height: 250)
                    .padding(.vertical, 20)
                    
                    // Quick Add Buttons
                    HStack(spacing: 20) {
                        QuickAddButton(amount: 100, action: { addWater(100) })
                        QuickAddButton(amount: 250, action: { addWater(250) })
                        QuickAddButton(amount: 500, action: { addWater(500) })
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Flux")
            .task {
                // Request location for weather when Dashboard appears
                weatherManager.requestLocationAndWeather()
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
    }
}

struct QuickAddButton: View {
    let amount: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                Text("\(amount)ml")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundColor(.blue)
            .frame(width: 70, height: 70)
            .background(Color.white)
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        }
    }
}
