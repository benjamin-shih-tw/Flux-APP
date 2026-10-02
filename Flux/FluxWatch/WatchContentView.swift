import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var connectivity: FluxWatchConnectivity

    private var progress: Double {
        min(Double(connectivity.todayTotalML) / Double(max(connectivity.goalML, 1)), 1)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)
                Text("Flux")
                    .font(.headline)
                Text("\(connectivity.todayTotalML) ml")
                    .font(.title3.bold().monospacedDigit())
                ProgressView(value: progress)
                    .tint(.blue)
                Text("Goal \(connectivity.goalML) ml")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    watchAddButton(100)
                    watchAddButton(250)
                }
                HStack(spacing: 8) {
                    watchAddButton(500)
                    Button {
                        connectivity.requestSnapshot()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 46, height: 34)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 8)
        }
        .onAppear {
            connectivity.requestSnapshot()
        }
    }

    private func watchAddButton(_ amount: Int) -> some View {
        Button {
            connectivity.addWater(amount)
        } label: {
            Text("+\(amount)")
                .font(.caption.bold().monospacedDigit())
                .frame(width: 46, height: 34)
        }
        .buttonStyle(.borderedProminent)
    }
}
