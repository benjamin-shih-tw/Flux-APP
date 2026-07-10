import SwiftUI

// MARK: - Forest Progress View
/// Shows daily water intake as a growing animated forest.
/// Each of the 5 trees represents 20% of the daily goal.
/// Logs trigger a cloud + raindrop animation.
struct ForestProgressView: View {
    let todayIntake: Int
    let dailyGoal: Int
    let waterTrigger: Int     // Increment externally to trigger raindrop animation
    
    @State private var drops: [RaindropModel] = []
    @State private var dropCounter: Int = 0
    
    private var progress: Double {
        min(Double(todayIntake) / Double(max(1, dailyGoal)), 1.0)
    }
    
    /// Each tree's growth level 0.0 to 1.0
    private func treeGrowth(index: Int) -> Double {
        let treeShare = 1.0 / 5.0
        let treeStart = treeShare * Double(index)
        let rawGrowth = (progress - treeStart) / treeShare
        return max(0, min(rawGrowth, 1.0))
    }
    
    var body: some View {
        ZStack {
            // Sky gradient
            LinearGradient(
                colors: [Color(red: 0.82, green: 0.93, blue: 1.0),
                         Color(red: 0.94, green: 0.98, blue: 1.0)],
                startPoint: .top, endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 28))
            
            // Sun
            Circle()
                .fill(Color.yellow.opacity(0.4))
                .frame(width: 50, height: 50)
                .offset(x: 100, y: -70)
            
            // Raindrops (appear when water is logged)
            ForEach(drops) { drop in
                RaindropView(drop: drop)
            }
            
            // Cloud (appears when logging)
            if !drops.isEmpty {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .blue.opacity(0.2), radius: 4)
                    .offset(y: -80)
                    .transition(.scale.combined(with: .opacity))
            }
            
            // Ground hill
            GroundShape()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.45, green: 0.76, blue: 0.35),
                                 Color(red: 0.35, green: 0.62, blue: 0.25)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(height: 100)
                .offset(y: 60)
            
            // Trees
            HStack(spacing: 22) {
                ForEach(0..<5, id: \.self) { i in
                    TreeView(growth: treeGrowth(index: i))
                }
            }
            .offset(y: 20)
            
            // Stats overlay (top left)
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(todayIntake) ml")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundColor(.black.opacity(0.75))
                        Text("of \(dailyGoal) ml")
                            .font(.caption)
                            .foregroundColor(.black.opacity(0.4))
                    }
                    Spacer()
                    // Percentage badge
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(progress >= 1.0 ? Color.green : Color.blue)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                Spacer()
            }
            
            // 🎉 Celebration when goal reached
            if progress >= 1.0 {
                VStack {
                    Spacer()
                    Text("🎉 Daily Goal Reached!")
                        .font(.caption).bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.green.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .onChange(of: waterTrigger) { _, _ in
            triggerRain()
        }
    }
    
    private func triggerRain() {
        let newDrops = (0..<6).map { _ in
            RaindropModel(x: CGFloat.random(in: -80...80))
        }
        withAnimation(.easeIn(duration: 0.2)) {
            drops = newDrops
        }
        // Clear drops after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.3)) {
                drops = []
            }
        }
    }
}

// MARK: - Tree View
struct TreeView: View {
    let growth: Double // 0.0 to 1.0
    
    private var stage: Int {
        switch growth {
        case 0:        return 0
        case 0..<0.4:  return 1
        case 0.4..<0.8: return 2
        default:       return 3
        }
    }
    
    private var treeColor: Color {
        switch stage {
        case 0: return Color(red: 0.6, green: 0.5, blue: 0.3).opacity(0.5)
        case 1: return Color(red: 0.5, green: 0.8, blue: 0.4)
        case 2: return Color(red: 0.3, green: 0.7, blue: 0.25)
        default: return Color(red: 0.15, green: 0.6, blue: 0.2)
        }
    }
    
    private var symbolName: String {
        stage == 0 ? "circle.fill" : stage == 1 ? "leaf.fill" : "tree.fill"
    }
    
    private var scale: CGFloat {
        switch stage {
        case 0: return 0.4
        case 1: return 0.65
        case 2: return 0.85
        default: return 1.0
        }
    }
    
    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 36))
            .foregroundColor(treeColor)
            .scaleEffect(scale)
            .shadow(color: treeColor.opacity(0.4), radius: stage == 3 ? 6 : 0)
            .animation(.spring(response: 0.6, dampingFraction: 0.65), value: stage)
            .animation(.spring(response: 0.6, dampingFraction: 0.65), value: scale)
    }
}

// MARK: - Raindrop
struct RaindropModel: Identifiable {
    let id = UUID()
    let x: CGFloat
}

struct RaindropView: View {
    let drop: RaindropModel
    @State private var offsetY: CGFloat = -60
    @State private var opacity: Double = 0.9
    
    var body: some View {
        Capsule()
            .fill(Color(red: 0.3, green: 0.6, blue: 1.0).opacity(opacity))
            .frame(width: 3, height: 10)
            .offset(x: drop.x, y: offsetY)
            .onAppear {
                withAnimation(.easeIn(duration: 0.8).delay(Double.random(in: 0...0.3))) {
                    offsetY = 60
                    opacity = 0
                }
            }
    }
}

// MARK: - Ground Shape
struct GroundShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height * 0.4))
        p.addCurve(
            to: CGPoint(x: rect.width, y: rect.height * 0.3),
            control1: CGPoint(x: rect.width * 0.3, y: rect.height * 0.0),
            control2: CGPoint(x: rect.width * 0.7, y: rect.height * 0.5)
        )
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.closeSubpath()
        return p
    }
}
