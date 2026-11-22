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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("成長森林")
                        .font(.fluxFont(.subheadline, weight: .semibold))
                    Spacer()
                    Text("等級 \(Int(progress * 5))")
                        .font(.fluxFont(.caption))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<5, id: \.self) { index in
                        TreeView(growth: treeGrowth(index: index))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color.green.opacity(0.2))
                        .frame(height: 2)
                }
            }
            .padding(15)

            ForEach(drops) { drop in
                RaindropView(drop: drop)
            }
        }
        .frame(height: 102)
        .fluxCard()
        .onChange(of: waterTrigger) { _, _ in triggerRain() }
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
        case 0: return Color.white.opacity(0.24)
        case 1: return Color(red: 0.41, green: 0.68, blue: 0.58)
        case 2: return Color(red: 0.32, green: 0.72, blue: 0.57)
        default: return Color(red: 0.34, green: 0.83, blue: 0.61)
        }
    }
    
    private var symbolName: String {
        "tree.fill"
    }
    
    private var scale: CGFloat {
        switch stage {
        case 0: return 0.8
        case 1: return 0.86
        case 2: return 0.93
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
