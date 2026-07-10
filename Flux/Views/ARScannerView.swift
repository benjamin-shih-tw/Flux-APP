import SwiftUI
import SwiftData

struct ARScannerView: View {
    @State private var isDetecting = false
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [10]))
                        .frame(width: 200, height: 300)
                    
                    if isDetecting {
                        HStack(spacing: 15) {
                            ARFloatingButton(amount: 250) { addWater(250) }
                            ARFloatingButton(amount: 500) { addWater(500) }
                        }
                        .offset(x: 120, y: 0)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                Spacer()
                
                Text("Point camera at your water bottle")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    isDetecting = true
                }
            }
        }
        .onDisappear {
            isDetecting = false
        }
    }
    
    private func addWater(_ amount: Int) {
        let impact = UIImpactFeedbackGenerator(style: .heavy)
        impact.impactOccurred()
        
        let record = WaterRecord(amountML: amount)
        modelContext.insert(record)
        
        // Briefly hide buttons to simulate successful scan
        withAnimation { isDetecting = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation { isDetecting = true }
        }
    }
}

struct ARFloatingButton: View {
    let amount: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("+\(amount)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.blue)
                .clipShape(Capsule())
                .shadow(color: .blue.opacity(0.4), radius: 10, x: 0, y: 5)
        }
    }
}
