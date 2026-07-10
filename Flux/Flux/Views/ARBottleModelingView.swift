import SwiftUI
import RealityKit
import ARKit
import SwiftData

// MARK: - AR Bottle Modeling View
/// Guides the user to tap two points on their bottle (top rim and bottom) using ARKit plane detection.
/// The AR system measures the real-world distance between the two taps to calculate bottle height.
/// Diameter is entered manually since measuring it with one camera is unreliable.
struct ARBottleModelingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // AR measurement state
    @State private var topPoint: SIMD3<Float>? = nil
    @State private var bottomPoint: SIMD3<Float>? = nil
    @State private var measuredHeightCM: Double? = nil
    @State private var arSessionState: ARTrackingState = .initializing

    // Bottle metadata inputs
    @State private var bottleName: String = "My Bottle"
    @State private var totalVolumeML: String = "500"
    @State private var diameterCM: String = "7"

    // UI flow
    @State private var currentStep: MeasureStep = .tapTop
    @State private var showManualEntry = false
    @State private var showSaveConfirmation = false

    enum MeasureStep { case tapTop, tapBottom, review }

    var body: some View {
        ZStack {
            // ARKit view layer
            ARViewRepresentable(
                onTap: handleARTap,
                onSessionStateChange: { arSessionState = $0 },
                topPoint: topPoint,
                bottomPoint: bottomPoint
            )
            .ignoresSafeArea()

            // UI overlay
            VStack {
                // Top bar
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white, Color.black.opacity(0.5))
                    }
                    Spacer()
                    Text("Bottle Setup")
                        .font(.headline).bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                    Spacer()
                    Button {
                        showManualEntry = true
                    } label: {
                        Image(systemName: "keyboard")
                            .font(.system(size: 24))
                            .foregroundStyle(.white, Color.black.opacity(0.5))
                    }
                }
                .padding()

                Spacer()

                // AR status indicator
                if arSessionState == .initializing {
                    Label("Scanning surfaces…", systemImage: "viewfinder")
                        .font(.caption).bold()
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                }

                Spacer()

                // Bottom instruction panel
                VStack(spacing: 16) {
                    // Step indicator
                    HStack(spacing: 8) {
                        StepDot(index: 0, current: currentStep == .tapTop ? 0 : currentStep == .tapBottom ? 1 : 2)
                        Rectangle().frame(height: 2).foregroundColor(.blue.opacity(0.5))
                        StepDot(index: 1, current: currentStep == .tapTop ? 0 : currentStep == .tapBottom ? 1 : 2)
                        Rectangle().frame(height: 2).foregroundColor(.blue.opacity(0.5))
                        StepDot(index: 2, current: currentStep == .tapTop ? 0 : currentStep == .tapBottom ? 1 : 2)
                    }
                    .padding(.horizontal, 40)

                    // Instruction text
                    Group {
                        switch currentStep {
                        case .tapTop:
                            VStack(spacing: 6) {
                                Text("Step 1: Tap the top rim of your bottle")
                                    .font(.headline).bold()
                                Text("Point the camera at the mouth of the bottle and tap the screen where the rim is.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                            }
                        case .tapBottom:
                            VStack(spacing: 6) {
                                Text("Step 2: Tap the bottom of your bottle")
                                    .font(.headline).bold()
                                Text("Now pan down and tap the base of the bottle to measure its height.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                            }
                        case .review:
                            if let h = measuredHeightCM {
                                VStack(spacing: 6) {
                                    Text("Measured Height: \(String(format: "%.1f", h)) cm")
                                        .font(.headline).bold()
                                        .foregroundColor(.blue)
                                    Text("Looks good? Fill in the details below and save.")
                                        .font(.caption).foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                    // Review form (Step 3)
                    if currentStep == .review {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Name").frame(width: 80, alignment: .leading)
                                TextField("e.g. Hydro Flask 500ml", text: $bottleName)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("Volume (ml)").frame(width: 80, alignment: .leading)
                                TextField("e.g. 500", text: $totalVolumeML)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.numberPad)
                            }
                            HStack {
                                Text("Diameter (cm)").frame(width: 80, alignment: .leading)
                                TextField("e.g. 7", text: $diameterCM)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.decimalPad)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.9))
                        .cornerRadius(16)

                        Button(action: saveBottle) {
                            Text("Save Bottle Profile")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(16)
                        }
                    }

                    // Reset button
                    if currentStep != .tapTop {
                        Button {
                            resetMeasurement()
                        } label: {
                            Text("Reset")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.black.opacity(0.75))
                )
                .padding()
            }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualBottleEntrySheet(onSave: { name, volume, height, diameter in
                saveBottleWithValues(name: name, volume: volume, heightCM: height, diameterCM: diameter)
            })
            .presentationDetents([.medium])
        }
        .alert("Bottle Saved!", isPresented: $showSaveConfirmation) {
            Button("Done") { dismiss() }
        } message: {
            Text("\(bottleName) has been added to your bottle list.")
        }
    }

    // MARK: - Logic
    private func handleARTap(worldPosition: SIMD3<Float>) {
        switch currentStep {
        case .tapTop:
            topPoint = worldPosition
            withAnimation { currentStep = .tapBottom }
        case .tapBottom:
            bottomPoint = worldPosition
            if let top = topPoint {
                // Calculate Euclidean distance between the two 3D points
                let diff = worldPosition - top
                let distanceMeters = sqrt(diff.x*diff.x + diff.y*diff.y + diff.z*diff.z)
                measuredHeightCM = Double(distanceMeters) * 100.0
            }
            withAnimation { currentStep = .review }
        case .review:
            break
        }
    }

    private func resetMeasurement() {
        topPoint = nil
        bottomPoint = nil
        measuredHeightCM = nil
        withAnimation { currentStep = .tapTop }
    }

    private func saveBottle() {
        let volume = Double(totalVolumeML) ?? 500
        let height = measuredHeightCM ?? 20
        let diameter = Double(diameterCM) ?? 7
        saveBottleWithValues(name: bottleName, volume: volume, heightCM: height, diameterCM: diameter)
    }

    private func saveBottleWithValues(name: String, volume: Double, heightCM: Double, diameterCM: Double) {
        // Unset previous defaults
        let fetchDescriptor = FetchDescriptor<BottleProfile>(predicate: #Predicate { $0.isDefault == true })
        if let existing = try? modelContext.fetch(fetchDescriptor) {
            existing.forEach { $0.isDefault = false }
        }
        let profile = BottleProfile(
            name: name,
            totalVolumeMl: volume,
            heightCM: heightCM,
            diameterCM: diameterCM,
            isDefault: true
        )
        modelContext.insert(profile)
        showSaveConfirmation = true
    }
}

// MARK: - Step Dot Indicator
struct StepDot: View {
    let index: Int
    let current: Int
    var body: some View {
        Circle()
            .fill(index <= current ? Color.blue : Color.gray.opacity(0.4))
            .frame(width: 12, height: 12)
    }
}

// MARK: - Manual Entry Fallback
struct ManualBottleEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (String, Double, Double, Double) -> Void

    @State private var name = "My Bottle"
    @State private var volume = "500"
    @State private var height = "20"
    @State private var diameter = "7"

    var body: some View {
        NavigationStack {
            Form {
                Section("Bottle Info") {
                    TextField("Name", text: $name)
                    TextField("Total Volume (ml)", text: $volume).keyboardType(.numberPad)
                    TextField("Height (cm)", text: $height).keyboardType(.decimalPad)
                    TextField("Opening Diameter (cm)", text: $diameter).keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Manual Entry")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let v = Double(volume) ?? 500
                        let h = Double(height) ?? 20
                        let d = Double(diameter) ?? 7
                        onSave(name, v, h, d)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
