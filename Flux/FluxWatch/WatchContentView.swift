import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var connectivity: FluxWatchConnectivity
    @State private var showCustomPicker = false

    private let accent = Color(red: 0.25, green: 0.67, blue: 1.0)

    private var progress: Double {
        min(Double(connectivity.todayTotalML) / Double(max(connectivity.goalML, 1)), 1.0)
    }

    private var percentComplete: Int {
        Int((progress * 100).rounded())
    }

    var body: some View {
        TabView {
            hydrationMainPage
            activityAndSyncPage
        }
        .tabViewStyle(.verticalPage)
        .sheet(isPresented: $showCustomPicker) {
            WatchCustomAmountSheet(accent: accent) { amount in
                connectivity.addWater(amount)
            }
        }
        .onAppear {
            connectivity.requestSnapshot()
        }
    }

    private var hydrationMainPage: some View {
        ScrollView {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AngularGradient(
                                colors: [Color.cyan, accent, Color.blue],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.35), value: progress)

                    VStack(spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: "drop.fill")
                                .font(.caption2)
                                .foregroundStyle(accent)
                            Text("\(percentComplete)%")
                                .font(.caption2.bold().monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text("\(connectivity.todayTotalML)")
                            .font(.title3.bold().monospacedDigit())
                            .minimumScaleFactor(0.75)
                        Text("/ \(connectivity.goalML) ml")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 112, height: 112)
                .padding(.top, 2)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                    Text(statusSubtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    if connectivity.streakDays > 0 {
                        Text("· 🔥\(connectivity.streakDays)d")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        watchAddButton(100)
                        watchAddButton(250)
                    }
                    HStack(spacing: 6) {
                        watchAddButton(500)
                        Button {
                            showCustomPicker = true
                        } label: {
                            Label("Custom", systemImage: "dial.medium")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var activityAndSyncPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Today's Log")
                        .font(.headline)
                    Spacer()
                    Button {
                        connectivity.requestSnapshot()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                if let latest = connectivity.latestEntry {
                    Button(role: .destructive) {
                        connectivity.undoLastEntry()
                    } label: {
                        Label("Undo +\(latest.amountML) ml", systemImage: "arrow.uturn.backward")
                            .font(.caption2.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                if connectivity.activeEnergyKCal > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "figure.run")
                            .foregroundStyle(accent)
                        Text("Workout +\(connectivity.activeEnergyKCal) ml")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if connectivity.recentEntries.isEmpty {
                    Text("No drinks logged yet today.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(connectivity.recentEntries.prefix(5)) { entry in
                        HStack {
                            Text("+\(entry.amountML) ml")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(accent)
                            Spacer()
                            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text(connectivity.isReachable ? "iPhone connected" : "Offline · queued sync")
                        .font(.caption2)
                        .foregroundStyle(connectivity.isReachable ? .green : .secondary)
                    if connectivity.pendingEventCount > 0 {
                        Text("\(connectivity.pendingEventCount) pending transfer(s)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let syncedAt = connectivity.lastSyncDate {
                        Text("Synced \(syncedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private var statusDotColor: Color {
        if connectivity.pendingEventCount > 0 { return .orange }
        return connectivity.isReachable ? .green : .gray
    }

    private var statusSubtitle: String {
        if connectivity.isSyncing { return "Syncing…" }
        if connectivity.pendingEventCount > 0 { return "\(connectivity.pendingEventCount) queued" }
        return connectivity.isReachable ? "Synced" : "Offline"
    }

    private func watchAddButton(_ amount: Int) -> some View {
        Button {
            connectivity.addWater(amount)
        } label: {
            Text("+\(amount)")
                .font(.caption.bold().monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
    }
}

private struct WatchCustomAmountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let accent: Color
    let onLog: (Int) -> Void

    @State private var amountML: Double = 200

    private var roundedAmount: Int {
        let stepped = (amountML / 25.0).rounded() * 25.0
        return min(1000, max(50, Int(stepped)))
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Custom Amount")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Text("\(roundedAmount) ml")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(accent)
                .focusable(true)
                .digitalCrownRotation(
                    $amountML,
                    from: 50,
                    through: 1000,
                    by: 25,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )

            HStack(spacing: 10) {
                Button {
                    amountML = max(50, amountML - 25)
                } label: {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    amountML = min(1000, amountML + 25)
                } label: {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                onLog(roundedAmount)
                dismiss()
            } label: {
                Text("Log +\(roundedAmount) ml")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
        }
        .padding(.horizontal, 6)
    }
}
