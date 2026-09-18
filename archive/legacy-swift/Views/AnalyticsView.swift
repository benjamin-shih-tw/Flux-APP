import SwiftUI
import SwiftData

struct AnalyticsView: View {
    @Query private var settingsList: [UserSettings]
    @Environment(\.modelContext) private var modelContext
    
    private var currentSettings: UserSettings {
        if let first = settingsList.first { return first }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }
    
    let daysInMonth = 30
    let activeDays: Set<Int> = [1, 2, 3, 4, 7, 8, 9, 10, 11, 14, 15, 16] // Keep mock for UI layout
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Streak Card
                        VStack(spacing: 10) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.orange)
                            Text("\(currentSettings.currentStreak) Days")
                                .font(.system(size: 32, weight: .black, design: .rounded))
                            Text("Current Streak")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                        .background(Color.white)
                        .cornerRadius(20)
                        .padding(.horizontal)
                        
                        // Heatmap (Visual Mock)
                        VStack(alignment: .leading) {
                            Text("This Month")
                                .font(.headline)
                                .padding(.horizontal)
                            
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                                ForEach(1...daysInMonth, id: \.self) { day in
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(activeDays.contains(day) ? Color.blue : Color.blue.opacity(0.1))
                                        .aspectRatio(1, contentMode: .fit)
                                }
                            }
                            .padding()
                            .background(Color.white)
                            .cornerRadius(20)
                            .padding(.horizontal)
                        }
                        
                        // Streak Freeze Store
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
                                // Mock purchase
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
                    .padding(.top)
                }
            }
            .navigationTitle("Analytics")
        }
    }
}
