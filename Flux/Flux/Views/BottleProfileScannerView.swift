import SwiftUI
import SwiftData
import UIKit

struct BottleProfileScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allBottles: [BottleProfile]

    @State private var step: SetupStep = .measureHeight
    @State private var measuredHeightCM: Double?

    @State private var showCamera = false
    @State private var capturedImage: UIImage?
    @State private var overlayImage: UIImage?
    @State private var rawProfiles: [[CGPoint]] = []
    @State private var scannedOverlays: [UIImage] = []
    @State private var scannedAppearances: [BottleAppearance] = []
    @State private var displayMultiProfiles: [[CGPoint]] = []
    @State private var detectedAppearance = BottleAppearance.fallback

    private let scanAngles = Array(stride(from: 0, through: 315, by: 45))

    @State private var isProcessing = false
    @State private var bottleName = "My Custom Bottle"
    @State private var bottleCapacityML = "500"
    @State private var diameterCM = "7"
    @State private var computedVolumeML: Double = 0
    @State private var displayProfile: [CGPoint] = []
    @State private var physicalProfile: [(height: Double, radius: Double)] = []

    @State private var showError = false
    @State private var errorMessage = ""

    enum SetupStep: Int, CaseIterable {
        case measureHeight = 1
        case captureProfile = 2
        case review = 3

        var title: String {
            switch self {
            case .measureHeight: return "Measure Height"
            case .captureProfile: return "Scan Shape"
            case .review: return "Review & Save"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepIndicator
                    .padding()

                switch step {
                case .measureHeight:
                    measureHeightStep
                case .captureProfile:
                    captureProfileStep
                case .review:
                    reviewStep
                }
            }
            .navigationTitle("Bottle Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if step == .measureHeight {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Back") { goBack() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if step != .measureHeight {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPickerView(image: $capturedImage)
                    .ignoresSafeArea()
                    .onDisappear {
                        if let img = capturedImage {
                            processImage(img)
                        }
                    }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { s in
                HStack(spacing: 4) {
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                    if s != .review {
                        Rectangle()
                            .fill(s.rawValue < step.rawValue ? Color.blue : Color.gray.opacity(0.3))
                            .frame(height: 2)
                    }
                }
            }
        }
        .overlay {
            HStack {
                ForEach(SetupStep.allCases, id: \.rawValue) { s in
                    Text(s.title)
                        .font(.caption2)
                        .foregroundColor(s == step ? .blue : .gray)
                        .frame(maxWidth: .infinity)
                }
            }
            .offset(y: 20)
        }
        .padding(.bottom, 24)
    }

    // MARK: - Step 1: AR Height

    private var measureHeightStep: some View {
        VStack(spacing: 16) {
            Text("First, measure your bottle's real height with AR.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            ARHeightMeasurementView(
                measuredHeightCM: $measuredHeightCM,
                onComplete: {
                    guard measuredHeightCM != nil else { return }
                    withAnimation { step = .captureProfile }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }

    // MARK: - Step 2: Side Profile Photo

    private var captureProfileStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let h = measuredHeightCM {
                    Label("Height: \(String(format: "%.1f", h)) cm", systemImage: "ruler")
                        .font(.caption).bold()
                        .foregroundColor(.blue)
                }

                VStack(spacing: 8) {
                    Text("Scan all sides of your bottle")
                        .font(.headline)
                    Text("Keep it upright on a plain background. Take 8 photos, turning the bottle 45° after each scan.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(scanAngles.enumerated()), id: \.offset) { index, angle in
                        VStack(spacing: 4) {
                            Image(systemName: index < rawProfiles.count ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(index < rawProfiles.count ? .green : (index == rawProfiles.count ? .blue : .gray.opacity(0.4)))
                            Text("\(angle)°")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 36)

                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.05), radius: 10, y: 5)

                    if let image = overlayImage ?? capturedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 40))
                                .foregroundColor(.gray.opacity(0.5))
                            Text("Angle 0° ready")
                                .font(.headline)
                                .foregroundColor(.blue)
                        }
                    }

                    if isProcessing {
                        Color.black.opacity(0.5)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        VStack {
                            ProgressView().tint(.white).scaleEffect(1.5)
                            Text("Extracting this side…")
                                .foregroundColor(.white)
                                .padding(.top)
                        }
                    }
                }
                .frame(height: 300)
                .padding(.horizontal)

                if rawProfiles.count < scanAngles.count {
                    let angle = scanAngles[rawProfiles.count]
                    Label(
                        angle == 0 ? "Start with the bottle facing forward" : "Turn the bottle clockwise to \(angle)°",
                        systemImage: angle == 0 ? "arrow.forward" : "rotate.3d"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Button {
                        capturedImage = nil
                        showCamera = true
                    } label: {
                        Label("Capture \(angle)° side", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .disabled(isProcessing)
                } else {
                    Label("All 8 sides captured", systemImage: "checkmark.circle.fill")
                        .font(.caption).bold()
                        .foregroundColor(.green)

                    Button("Build 3D Model") {
                        prepareReview()
                        withAnimation { step = .review }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }

                if !rawProfiles.isEmpty {
                    Button("Retake last side") {
                        rawProfiles.removeLast()
                        if !scannedOverlays.isEmpty { scannedOverlays.removeLast() }
                        if !scannedAppearances.isEmpty { scannedAppearances.removeLast() }
                        overlayImage = scannedOverlays.last
                    }
                    .font(.caption)
                    .foregroundColor(.gray)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Step 3: Review

    private var reviewStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let overlay = overlayImage {
                    Image(uiImage: overlay)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }

                VStack(spacing: 16) {
                    formField("Bottle Name", text: $bottleName)
                    formField("Capacity (ml)", text: $bottleCapacityML, keyboard: .numberPad)
                    formField("Opening Diameter (cm)", text: $diameterCM, keyboard: .decimalPad)
                }
                .padding()
                .background(Color.white)
                .cornerRadius(16)
                .padding(.horizontal)

                // This is the exact lightweight model that will appear on Dashboard.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("3D Bottle Preview", systemImage: "cube.transparent")
                            .font(.headline)
                        Spacer()
                        Text("Drag to rotate")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    DashboardBottle3DView(
                        fillFraction: 1,
                        customProfile: displayProfile,
                        multiAngleProfiles: displayMultiProfiles,
                        bottleColor: UIColor(
                            red: CGFloat(detectedAppearance.red),
                            green: CGFloat(detectedAppearance.green),
                            blue: CGFloat(detectedAppearance.blue),
                            alpha: 1
                        )
                    )
                        .frame(height: 220)
                        .background(Color.blue.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding()
                .background(Color.white)
                .cornerRadius(16)
                .padding(.horizontal)

                // Volume validation card
                VStack(alignment: .leading, spacing: 8) {
                    Text("Volume Validation")
                        .font(.headline)
                    HStack {
                        Text("Label capacity")
                        Spacer()
                        Text("\(bottleCapacityML) ml")
                            .bold()
                    }
                    HStack {
                        Text("Computed from shape")
                        Spacer()
                        Text("\(Int(computedVolumeML)) ml")
                            .bold()
                            .foregroundColor(volumeMatchColor)
                    }
                    if let label = Double(bottleCapacityML), label > 0 {
                        let diff = abs(computedVolumeML - label) / label
                        if diff > 0.15 {
                            Label("Shape differs >15% from label — consider retaking photo", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            Label("Shape matches label capacity", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
                .padding()
                .background(Color.white)
                .cornerRadius(16)
                .padding(.horizontal)

                Button(action: saveProfile) {
                    Text("Save Bottle Profile")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(16)
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
        }
    }

    private var volumeMatchColor: Color {
        guard let label = Double(bottleCapacityML), label > 0 else { return .blue }
        let diff = abs(computedVolumeML - label) / label
        return diff > 0.15 ? .orange : .blue
    }

    // MARK: - Helpers

    private func formField(_ label: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).bold().foregroundColor(.gray)
            TextField(label, text: text)
                .keyboardType(keyboard)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func goBack() {
        switch step {
        case .captureProfile: step = .measureHeight
        case .review: step = .captureProfile
        default: break
        }
    }

    private func processImage(_ image: UIImage) {
        guard rawProfiles.count < scanAngles.count else { return }
        isProcessing = true
        Task {
            do {
                let result = try await BottleProfileExtraction.extractRightProfile(from: image)
                await MainActor.run {
                    self.rawProfiles.append(result.rawProfile)
                    self.scannedOverlays.append(result.overlayImage)
                    self.scannedAppearances.append(result.appearance)
                    self.overlayImage = result.overlayImage
                    self.capturedImage = nil
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    self.capturedImage = nil
                    self.isProcessing = false
                }
            }
        }
    }

    private func prepareReview() {
        guard rawProfiles.count >= 3,
              let height = measuredHeightCM,
              let diameter = Double(diameterCM) else { return }

        let geometryProfiles = BottleMeshGenerator.normalizeProfilesForGeometry(rawProfiles)
        let averageProfile = BottleMeshGenerator.averageProfiles(geometryProfiles)
        let openingRadius = diameter / 2.0
        let built = BottleMeshGenerator.buildProfiles(
            rawPoints: averageProfile,
            heightCM: height,
            openingRadiusCM: openingRadius
        )
        displayProfile = built.display
        displayMultiProfiles = BottleMeshGenerator.normalizeMultiAngleProfilesForDisplay(rawProfiles)
        detectedAppearance = BottleAppearanceExtractor.average(scannedAppearances)
        physicalProfile = built.physical
        computedVolumeML = BottleVolumeCalculator.totalVolumeML(profile: built.physical)
    }

    private func saveProfile() {
        guard let capacity = Double(bottleCapacityML), capacity > 0,
              let height = measuredHeightCM, height > 0,
              let diameter = Double(diameterCM), diameter > 0 else {
            errorMessage = "Enter valid capacity and bottle dimensions"
            showError = true
            return
        }

        // Rebuild with the values currently visible in Review, not stale values from before edits.
        prepareReview()
        guard !displayProfile.isEmpty, !physicalProfile.isEmpty else {
            errorMessage = "Profile not ready — retake the side photos"
            showError = true
            return
        }

        for bottle in allBottles { bottle.isDefault = false }

        let bottle = BottleProfile(
            name: bottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My Bottle" : bottleName,
            totalVolumeMl: capacity,
            heightCM: height,
            diameterCM: diameter,
            isDefault: true,
            contourXs: displayProfile.map { Double($0.x) },
            contourYs: displayProfile.map { Double($0.y) },
            profileRadiusCM: physicalProfile.map(\.radius),
            profileHeightCM: physicalProfile.map(\.height),
            computedVolumeML: computedVolumeML,
            multiAngleProfiles: displayMultiProfiles,
            appearance: detectedAppearance
        )

        modelContext.insert(bottle)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.delete(bottle)
            errorMessage = "Could not save the bottle model: \(error.localizedDescription)"
            showError = true
        }
    }
}
