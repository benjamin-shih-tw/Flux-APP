import SwiftUI
import AVFoundation
import SwiftData
import UIKit

// MARK: - Main AR Scanner View
struct ARScannerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WaterAPIManager.self) private var apiManager
    @Environment(BottleAlignmentManager.self) private var alignmentMonitor

    @Query(filter: #Predicate<BottleProfile> { $0.isDefault == true }) private var defaultBottles: [BottleProfile]
    @Query private var allBottles: [BottleProfile]
    @Query private var settingsList: [UserSettings]

    private var currentSettings: UserSettings {
        if let first = settingsList.first { return first }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }

    @State private var showCamera = false
    @State private var capturedImage: UIImage? = nil
    @State private var scanResult: WaterScanResult? = nil
    @State private var showResultSheet = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showBottleSelector = false
    @State private var showBottleProfileScanner = false

    // The bottle used for this scan
    private var activeBottle: BottleProfile? {
        defaultBottles.first ?? allBottles.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "waterbottle.fill")
                            .foregroundColor(.blue)
                        if let bottle = activeBottle {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bottle.name)
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(.white)
                                Text(bottle.displaySummary)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        } else {
                            Text("No bottle set up yet")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Button {
                            showBottleSelector = true
                        } label: {
                            Text("Change")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85))

                    AlignmentStatusCard(
                        title: alignmentMonitor.statusLabel,
                        detail: alignmentMonitor.statusDetail,
                        score: alignmentMonitor.alignmentScore,
                        isReady: alignmentMonitor.captureReady
                    )
                    .padding(.horizontal)
                    .padding(.top, 10)

                    Spacer()

                    // Camera viewfinder guide
                    ZStack {
                        Color.black.opacity(0.5)
                            .mask(
                                Rectangle()
                                    .overlay(
                                        Circle()
                                            .frame(width: 240, height: 240)
                                            .blendMode(.destinationOut)
                                    )
                            )

                        Circle()
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                            .frame(width: 240, height: 240)

                        Group {
                            Rectangle().frame(width: 1, height: 30).foregroundColor(.blue.opacity(0.7))
                            Rectangle().frame(width: 30, height: 1).foregroundColor(.blue.opacity(0.7))
                        }
                    }

                    Spacer()

                    VStack(spacing: 6) {
                        Text("Hold the phone directly above the bottle opening")
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.white)
                        Text(alignmentMonitor.guidanceMessage)
                            .font(.caption)
                            .foregroundColor(alignmentMonitor.captureReady ? .green : .gray)
                    }
                    .padding()

                    HStack(spacing: 34) {
                        Button {
                            showBottleProfileScanner = true
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "arkit")
                                    .font(.system(size: 24))
                                Text("Setup\nBottle")
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                            }
                            .foregroundColor(.white.opacity(0.72))
                            .frame(width: 70, height: 70)
                        }

                        Button {
                            if activeBottle == nil {
                                showBottleProfileScanner = true
                                return
                            }

                            if alignmentMonitor.captureReady {
                                capturedImage = nil
                                showCamera = true
                            } else {
                                errorMessage = alignmentMonitor.guidanceMessage
                                showError = true
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(activeBottle == nil || !alignmentMonitor.captureReady ? Color.gray : Color.blue)
                                    .frame(width: 80, height: 80)
                                if apiManager.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: activeBottle == nil ? "plus" : (alignmentMonitor.captureReady ? "camera.fill" : "lock.fill"))
                                        .font(.system(size: 28))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .disabled(apiManager.isLoading)

                        Button {
                            showBottleSelector = true
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 24))
                                Text("Bottles")
                                    .font(.caption)
                            }
                            .foregroundColor(.white.opacity(0.72))
                            .frame(width: 70, height: 70)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                alignmentMonitor.startMonitoring()
            }
            .onDisappear {
                alignmentMonitor.stopMonitoring()
            }
            .sheet(isPresented: $showCamera) {
                CameraPickerView(image: $capturedImage)
                    .ignoresSafeArea()
                    .onDisappear {
                        if let img = capturedImage {
                            Task { await sendImageToAPI(img) }
                        }
                    }
            }
            .sheet(isPresented: $showResultSheet) {
                if let result = scanResult, let bottle = activeBottle {
                    WaterResultSheet(
                        result: result,
                        bottleName: bottle.name,
                        onConfirm: {
                            applyScanResult(result, bottle: bottle)
                            showResultSheet = false
                            scanResult = nil
                            capturedImage = nil
                        },
                        onDismiss: {
                            showResultSheet = false
                            scanResult = nil
                            capturedImage = nil
                        }
                    )
                    .presentationDetents([.medium, .large])
                }
            }
            .sheet(isPresented: $showBottleSelector) {
                BottleSelectorSheet()
                    .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showBottleProfileScanner) {
                BottleProfileScannerView()
            }
            .alert("Scan Failed", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Helpers
    private func sendImageToAPI(_ image: UIImage) async {
        guard let bottle = activeBottle else { return }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return }

        do {
            let result = try await apiManager.scanWaterVolume(
                imageData: jpeg,
                bottle: bottle,
                imuAlignmentScore: alignmentMonitor.alignmentScore,
                lastRemainingML: currentSettings.lastScanRemainingML
            )
            await MainActor.run {
                scanResult = result
                showResultSheet = true
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func applyScanResult(_ result: WaterScanResult, bottle: BottleProfile) {
        if let consumed = result.consumedML, consumed > 0 {
            addWater(Int(consumed.rounded()))
        }

        currentSettings.lastScanRemainingML = result.remainingML
        currentSettings.lastScanBottleCapacityML = bottle.totalVolumeMl
        currentSettings.lastScanTimestamp = Date()
        currentSettings.lastScanWaterHeightCM = result.waterDepthCM ?? result.waterHeightCM ?? 0

        if let outerPx = result.outerRadiusPx, bottle.calibrationOuterRadiusPx <= 0 {
            bottle.calibrationOuterRadiusPx = outerPx
        }
    }

    private func addWater(_ amount: Int) {
        let impact = UIImpactFeedbackGenerator(style: .heavy)
        impact.impactOccurred()
        let record = WaterRecord(amountML: amount)
        modelContext.insert(record)
    }
}

struct AlignmentStatusCard: View {
    let title: String
    let detail: String
    let score: Double
    let isReady: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "gyroscope")
                .font(.system(size: 20))
                .foregroundColor(isReady ? .green : .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .bold()
                    .foregroundColor(.white)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            Text("\(Int(score * 100))%")
                .font(.caption)
                .bold()
                .foregroundColor(isReady ? .green : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((isReady ? Color.green : Color.white).opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Result Confirmation Sheet
struct WaterResultSheet: View {
    let result: WaterScanResult
    let bottleName: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @Environment(WaterAPIManager.self) private var apiManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)

                VStack(spacing: 6) {
                    Text("Scan Complete")
                        .font(.title2)
                        .bold()
                    Text(bottleName)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }

                if let debugImg = apiManager.lastDebugImage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Detection Overlay")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.gray)
                        Image(uiImage: debugImg)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                        HStack(spacing: 12) {
                            Label("Green = bottle rim", systemImage: "circle")
                                .font(.caption2)
                                .foregroundColor(.green)
                            Label("Orange = water", systemImage: "circle")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal)
                }

                VStack(spacing: 12) {
                    HStack {
                        Text("Remaining")
                            .foregroundColor(.gray)
                        Spacer()
                        Text("\(Int(result.remainingML)) ml")
                            .font(.title3)
                            .bold()
                            .foregroundColor(.blue)
                    }

                    HStack {
                        Text("Water depth")
                            .foregroundColor(.gray)
                        Spacer()
                        if let depth = result.waterDepthCM {
                            Text(String(format: "%.1f cm", depth))
                                .font(.subheadline)
                                .bold()
                        } else {
                            Text("Not available")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    }

                    HStack {
                        Text("Confidence")
                            .foregroundColor(.gray)
                        Spacer()
                        Text(String(format: "%.0f%%", result.confidence * 100))
                            .font(.subheadline)
                            .bold()
                    }

                    HStack {
                        Text("Method")
                            .foregroundColor(.gray)
                        Spacer()
                        Text(result.methodUsed)
                            .font(.subheadline)
                            .bold()
                    }

                    if let consumed = result.consumedML, consumed > 0 {
                        HStack {
                            Text("You drank")
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(Int(consumed)) ml")
                                .font(.title3)
                                .bold()
                                .foregroundColor(.green)
                        }
                    } else if result.consumedML == nil {
                        Text("First scan - baseline recorded")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    if let h = result.waterHeightCM {
                        HStack {
                            Text("Surface height")
                                .foregroundColor(.gray)
                            Spacer()
                            Text(String(format: "%.1f cm", h))
                                .font(.subheadline)
                                .bold()
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.08))
                .cornerRadius(16)
                .padding(.horizontal)

                HStack(spacing: 16) {
                    Button(action: onDismiss) {
                        Text("Discard")
                            .font(.headline)
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(16)
                    }
                    Button(action: onConfirm) {
                        Text(result.consumedML != nil && (result.consumedML ?? 0) > 0 ? "Log Drink" : "Save Scan")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(16)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Bottle Selector Sheet
struct BottleSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var bottles: [BottleProfile]
    @State private var showBottleProfileScanner = false

    var body: some View {
        NavigationStack {
            List {
                if bottles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waterbottle")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No bottles set up yet")
                            .foregroundColor(.gray)
                        Text("Use AR Setup to scan your bottle's dimensions")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(bottles) { bottle in
                        HStack {
                            Image(systemName: bottle.isDefault ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(bottle.isDefault ? .blue : .gray)
                            VStack(alignment: .leading) {
                                Text(bottle.name).bold()
                                Text(bottle.displaySummary)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            bottles.forEach { $0.isDefault = false }
                            bottle.isDefault = true
                            dismiss()
                        }
                    }
                    .onDelete { indexSet in
                        indexSet.forEach { modelContext.delete(bottles[$0]) }
                    }
                }
            }
            .navigationTitle("My Bottles")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showBottleProfileScanner = true
                    } label: {
                        Label("Add Bottle", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showBottleProfileScanner) {
                BottleProfileScannerView()
            }
        }
    }
}

// MARK: - Camera Picker (UIImagePickerController wrapper)
struct CameraPickerView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .rear
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView

        init(_ parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
