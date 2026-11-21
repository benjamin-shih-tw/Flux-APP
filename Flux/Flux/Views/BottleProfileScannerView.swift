import SwiftUI
import SwiftData
import UIKit

/// Creates a bottle model from one side photo and its visible capacity label.
struct BottleProfileScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allBottles: [BottleProfile]

    @State private var step: SetupStep = .capture
    @State private var showCamera = false
    @State private var capturedImage: UIImage?
    @State private var overlayImage: UIImage?
    @State private var appearance = BottleAppearance.fallback
    @State private var fittedProfile: BottleVolumeCalculator.CapacityFittedProfile?
    @State private var detectedCapacityML: Int?
    @State private var isProcessing = false

    @State private var bottleName = "My Bottle"
    @State private var showError = false
    @State private var errorMessage = ""

    enum SetupStep {
        case capture
        case review
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .capture:
                    captureStep
                case .review:
                    reviewStep
                }
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Add Bottle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(step == .capture ? "Cancel" : "Back") {
                        if step == .capture {
                            dismiss()
                        } else {
                            withAnimation { step = .capture }
                        }
                    }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPickerView(image: $capturedImage)
                    .ignoresSafeArea()
                    .onDisappear {
                        if let capturedImage {
                            processImage(capturedImage)
                        }
                    }
            }
            .alert("Bottle setup failed", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var captureStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                stepIndicator

                VStack(spacing: 8) {
                    Text("Take one side photo")
                        .font(.title2.bold())
                    Text("Stand the bottle upright against a plain background. Include the full outline and the printed capacity in the photo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))

                    if let image = overlayImage ?? capturedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 28))
                    } else {
                        VStack(spacing: 18) {
                            Image(systemName: "waterbottle")
                                .font(.system(size: 104, weight: .ultraLight))
                                .foregroundStyle(.blue)
                            Text("Keep the bottle centred and upright")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(.blue.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [9, 7]))

                    if isProcessing {
                        RoundedRectangle(cornerRadius: 28)
                            .fill(.black.opacity(0.45))
                        VStack(spacing: 12) {
                            ProgressView().tint(.white).scaleEffect(1.25)
                            Text("Building bottle shape…")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(height: 390)
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    captureTip(icon: "rectangle.portrait", text: "Show the entire bottle")
                    captureTip(icon: "waterbottle", text: "Remove the cap so the opening is visible")
                    captureTip(icon: "light.max", text: "Use even lighting without strong shadows")
                    captureTip(icon: "hand.raised.slash", text: "Remove your hand from the bottle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)

                Button {
                    capturedImage = nil
                    overlayImage = nil
                    detectedCapacityML = nil
                    showCamera = true
                } label: {
                    Label(capturedImage == nil ? "Take Photo" : "Retake Photo", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .disabled(isProcessing)
            }
            .padding(.vertical)
        }
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                stepIndicator

                HStack(alignment: .top, spacing: 16) {
                    if let overlayImage {
                        Image(uiImage: overlayImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 116, height: 164)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label(qualityTitle, systemImage: qualityIcon)
                            .font(.headline)
                            .foregroundStyle(qualityColor)
                        Text(qualityDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Retake photo") {
                            withAnimation { step = .capture }
                        }
                        .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal)

                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bottle name")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField("My Bottle", text: $bottleName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Capacity on the label")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("\(detectedCapacityML ?? 0) ml")
                        Text("Dimensions are estimated from the outline and printed capacity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Bottle preview", systemImage: "cube.transparent")
                            .font(.headline)
                        Spacer()
                        if let fittedProfile {
                            Text("Geometry ≈ \(Int(fittedProfile.computedVolumeML.rounded())) ml")
                                .font(.subheadline.bold())
                                .foregroundStyle(.blue)
                        }
                    }

                    DashboardBottle3DView(
                        fillFraction: 1,
                        customProfile: displayProfile,
                        bottleColor: UIColor(
                            red: CGFloat(appearance.red),
                            green: CGFloat(appearance.green),
                            blue: CGFloat(appearance.blue),
                            alpha: 1
                        )
                    )
                    .frame(height: 240)
                    .background(Color.blue.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    if let fittedProfile {
                        HStack {
                            modelMetric("Model height", value: String(format: "%.1f cm", fittedProfile.heightCM))
                            Divider().frame(height: 34)
                            let widestDiameter = (fittedProfile.physical.map(\.radius).max() ?? 0) * 2
                            modelMetric("Max diameter", value: String(format: "%.1f cm", widestDiameter))
                        }
                    }
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal)

                Button(action: saveProfile) {
                    Text("Save Bottle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 24)
                .disabled(!canSave)
            }
            .padding(.vertical)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 7) {
            stepBadge(number: 1, title: "Photo", active: step == .capture)
            Capsule()
                .fill(step != .capture ? Color.blue : Color.secondary.opacity(0.2))
                .frame(height: 3)
            stepBadge(number: 2, title: "Details", active: step == .review)
        }
        .padding(.horizontal, 20)
    }

    private func stepBadge(number: Int, title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: 24, height: 24)
                .background(active ? Color.blue : Color.secondary.opacity(0.15))
                .clipShape(Circle())
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private func captureTip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func modelMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.bold())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var displayProfile: [CGPoint] {
        guard let fittedProfile else { return [] }
        let points = fittedProfile.physical.map { CGPoint(x: $0.radius, y: $0.height) }
        return BottleMeshGenerator.normalizeProfileForDisplay(points)
    }

    private var capacity: Double? {
        detectedCapacityML.map(Double.init)
    }

    private var canSave: Bool {
        fittedProfile != nil
            && (fittedProfile?.qualityScore ?? 0) >= 0.45
            && capacity != nil
            && !bottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var qualityTitle: String {
        switch fittedProfile?.qualityScore ?? 0 {
        case 0.82...: return "Excellent shape capture"
        case 0.65...: return "Good shape capture"
        case 0.45...: return "Usable shape capture"
        default: return "Retake recommended"
        }
    }

    private var qualityDetail: String {
        switch fittedProfile?.qualityScore ?? 0 {
        case 0.82...: return "The outline is smooth and has a realistic bottle proportion."
        case 0.65...: return "The model is ready. A cleaner background may improve the outline."
        case 0.45...: return "The model can be saved, but a centred photo will be more reliable."
        default: return "The outline is incomplete or distorted. Use a plain background and include the whole bottle."
        }
    }

    private var qualityIcon: String {
        (fittedProfile?.qualityScore ?? 0) >= 0.65 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var qualityColor: Color {
        switch fittedProfile?.qualityScore ?? 0 {
        case 0.65...: return .green
        case 0.45...: return .orange
        default: return .red
        }
    }

    private func processImage(_ image: UIImage) {
        isProcessing = true
        Task {
            do {
                let result = try await BottleProfileExtraction.extractRightProfile(from: image)
                await MainActor.run {
                    overlayImage = result.overlayImage
                    appearance = result.appearance
                    detectedCapacityML = result.detectedCapacityML
                    isProcessing = false
                    guard let capacity = result.detectedCapacityML, (100...5000).contains(capacity) else {
                        errorMessage = "Retake with the printed capacity (100–5000 ml) visible. A readable capacity label is required."
                        showError = true
                        return
                    }
                    fittedProfile = BottleVolumeCalculator.fitProfileToCapacity(rawPoints: result.rawProfile, capacityML: Double(capacity))
                    withAnimation { step = .review }
                }
            } catch {
                await MainActor.run {
                    capturedImage = nil
                    overlayImage = nil
                    isProcessing = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func saveProfile() {
        guard let capacity,
              let fittedProfile,
              fittedProfile.qualityScore >= 0.45 else {
            errorMessage = "Retake a clear photo of the full bottle and its printed capacity."
            showError = true
            return
        }

        for bottle in allBottles {
            bottle.isDefault = false
        }

        let display = displayProfile
        let bottle = BottleProfile(
            name: bottleName.trimmingCharacters(in: .whitespacesAndNewlines),
            totalVolumeMl: capacity,
            heightCM: fittedProfile.heightCM,
            diameterCM: fittedProfile.openingDiameterCM,
            isDefault: true,
            contourXs: display.map { Double($0.x) },
            contourYs: display.map { Double($0.y) },
            profileRadiusCM: fittedProfile.physical.map(\.radius),
            profileHeightCM: fittedProfile.physical.map(\.height),
            computedVolumeML: fittedProfile.computedVolumeML,
            appearance: appearance
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
