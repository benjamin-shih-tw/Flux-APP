import SwiftUI
import AVFoundation
import SwiftData
import UIKit

// MARK: - Main AR Scanner View
struct ARScannerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WaterAPIManager.self) private var apiManager

    @Query(filter: #Predicate<BottleProfile> { $0.isDefault == true }) private var defaultBottles: [BottleProfile]
    @Query private var allBottles: [BottleProfile]
    @Query private var settingsList: [UserSettings]

    private var currentSettings: UserSettings {
        if let first = settingsList.first { return first }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var submitting = false
    @State private var calibratedCapture: CalibratedWaterCapture?
    @State private var scanBottle: BottleProfile?
    @State private var scanBottleSignature: String?
    @State private var scanResult: WaterScanResult? = nil
    @State private var showResultSheet = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showBottleSelector = false
    @State private var showBottleProfileScanner = false
    @State private var showScanHelp = false

    // The bottle used for this scan
    private var activeBottle: BottleProfile? {
        defaultBottles.first ?? allBottles.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FluxTheme.background.ignoresSafeArea()
                RadialGradient(colors: [FluxTheme.accent.opacity(0.11), .clear], center: .center, startRadius: 30, endRadius: 320)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Text("Scan Bottle")
                            .font(.geist(size: 28, relativeTo: .largeTitle, weight: .bold))
                        Spacer()
                        Button { showScanHelp = true } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 18))
                                .frame(width: 38, height: 38)
                                .fluxCard(cornerRadius: 19)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Scan help")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                    HStack {
                        Image(systemName: "waterbottle.fill")
                            .font(.system(size: 25))
                            .foregroundColor(FluxTheme.accent)
                            .frame(width: 40)
                        if let bottle = activeBottle {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bottle.name)
                                    .font(.geist(.subheadline, weight: .semibold))
                                    .bold()
                                    .foregroundColor(.white)
                                Text(bottle.displaySummary)
                                    .font(.geist(.caption))
                                    .foregroundColor(.gray)
                            }
                        } else {
                            Text("No bottle set up yet")
                                .font(.geist(.caption))
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Button {
                            showBottleSelector = true
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .fluxCard(cornerRadius: 18)
                    .padding(.horizontal, 16)

                    Group {
                        if scenePhase == .active && !showBottleSelector && !showBottleProfileScanner && !showScanHelp && !showResultSheet && !showError {
                            CalibratedWaterCameraView(hasBottle: activeBottle != nil) { capture in
                                guard !submitting, let bottle = activeBottle else { return nil }
                                submitting = true
                                calibratedCapture = capture
                                scanBottle = bottle
                                scanBottleSignature = bottleSignature(bottle)
                                defer { submitting = false }
                                return await sendImageToAPI(capture)
                            }
                            .id(activeBottle?.measurementID)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 26))
                    .padding(.horizontal, 12)
                    .padding(.top, 13)

                    Spacer(minLength: 8)

                    HStack(spacing: 12) {
                        Button {
                            showBottleProfileScanner = true
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arkit")
                                    .font(.system(size: 18))
                                Text("Setup\nBottle")
                                    .font(.geist(size: 11, relativeTo: .caption, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(width: 98, height: 50)
                            .fluxCard(cornerRadius: 16)
                        }

                        Button {
                            showBottleSelector = true
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 18))
                                Text("Bottles")
                                    .font(.geist(size: 11, relativeTo: .caption, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(width: 98, height: 50)
                            .fluxCard(cornerRadius: 16)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .navigationBarHidden(true)
            .alert("Scan Bottle", isPresented: $showScanHelp) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("將瓶口內緣對齊圓框並保持水平，穩定後會自動拍攝。")
            }
            .sheet(isPresented: $showResultSheet) {
                if let result = scanResult, let bottle = scanBottle {
                    WaterResultSheet(
                        result: result,
                        bottleName: bottle.name,
                        onConfirm: {
                            applyScanResult(result, bottle: bottle)
                            showResultSheet = false
                            scanResult = nil
                        },
                        onDismiss: {
                            showResultSheet = false
                            scanResult = nil
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
    @MainActor
    private func sendImageToAPI(_ capture: CalibratedWaterCapture) async -> String? {
        guard let bottle = scanBottle,
              scanIsCurrent(bottle) else {
            errorMessage = "瓶子資料已變更，請重新拍攝。"
            showError = true
            return nil
        }
        guard let jpeg = capture.image.jpegData(compressionQuality: 0.85) else { return "影像編碼失敗，請重新對齊。" }
        let focalLengthPixels = capture.focalLengthPixels

        do {
            let previousScanAge = currentSettings.lastScanTimestamp.map {
                max(0, Date().timeIntervalSince($0))
            }
            // A scan baseline belongs to the bottle/capacity it was recorded
            // with.  Do not send a previous 1,500 ml bottle's value while the
            // user is measuring a newly selected 600 ml bottle: the API quite
            // correctly rejects that value before it can analyse the image.
            let previousRemaining: Double? = {
                guard currentSettings.lastScanTimestamp != nil,
                      currentSettings.lastScanBottleID == bottle.measurementID,
                      currentSettings.lastScanBottleCapacityML > 0,
                      abs(currentSettings.lastScanBottleCapacityML - bottle.totalVolumeMl)
                        <= max(1.0, bottle.totalVolumeMl * 0.01),
                      currentSettings.lastScanRemainingML.isFinite,
                      (0...bottle.totalVolumeMl).contains(currentSettings.lastScanRemainingML)
                else { return nil }
                return currentSettings.lastScanRemainingML
            }()

            let result = try await apiManager.scanWaterVolume(
                imageData: jpeg,
                bottle: bottle,
                imuAlignmentScore: capture.alignmentScore,
                lastRemainingML: previousRemaining,
                secondsSinceLastScan: previousScanAge,
                audioData: nil,
                acousticMetadataJSON: "{}",
                cameraFocalLengthPx: focalLengthPixels,
                phoneToRimCM: nil,
                surfaceMode: "auto",
                guidedRim: capture.rim
            )
            await MainActor.run {
                guard scanIsCurrent(bottle) else {
                    errorMessage = "量測期間瓶子資料已變更，請重新拍攝。"
                    showError = true
                    return
                }
                scanResult = result
                showResultSheet = true
            }
        } catch WaterAPIManager.APIError.retake(let reason) {
            if reason.contains("lighting") { return "水面與反光難以區分，請換個光線位置再對齊。" }
            if reason.contains("height") { return "水位有多種可能，請稍微改變拍攝距離再對齊。" }
            return reason
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        return nil
    }

    // Snapshot all geometric inputs so editing a bottle cannot reinterpret a scan.
    private func bottleSignature(_ bottle: BottleProfile) -> String {
        "\(bottle.measurementID)|\(bottle.totalVolumeMl)|\(bottle.heightCM)|\(bottle.diameterCM)|\(bottle.profileHeightCM)|\(bottle.profileRadiusCM)"
    }

    private func scanIsCurrent(_ bottle: BottleProfile) -> Bool {
        allBottles.contains { $0.measurementID == bottle.measurementID }
            && scanBottleSignature == bottleSignature(bottle)
    }

    private func applyScanResult(_ result: WaterScanResult, bottle: BottleProfile) {
        guard scanIsCurrent(bottle) else {
            errorMessage = "瓶子資料已變更，結果未保存；請重新拍攝。"
            showError = true
            return
        }
        if let consumed = result.consumedML, consumed > 0 {
            addWater(Int(consumed.rounded()))
        }

        currentSettings.lastScanBottleID = bottle.measurementID
        currentSettings.lastScanRemainingML = result.remainingML
        currentSettings.lastScanBottleCapacityML = bottle.totalVolumeMl
        currentSettings.lastScanTimestamp = calibratedCapture?.capturedAt ?? Date()
        currentSettings.lastScanWaterHeightCM = result.waterHeightCM ?? result.waterDepthCM.map { max(0, bottle.heightCM - $0) } ?? 0

        if let outerPx = result.outerRadiusPx, bottle.calibrationOuterRadiusPx <= 0 {
            bottle.calibrationOuterRadiusPx = outerPx
        }
    }

    private func addWater(_ amount: Int) {
        let impact = UIImpactFeedbackGenerator(style: .heavy)
        impact.impactOccurred()
        let record = WaterRecord(amountML: amount)
        modelContext.insert(record)
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayTotal = (try? modelContext.fetch(FetchDescriptor<WaterRecord>()))?
            .filter { $0.timestamp >= todayStart }
            .reduce(0) { $0 + $1.amountML } ?? amount
        watchManager.sendWaterAdded(
            amountML: amount,
            todayTotalML: todayTotal,
            goalML: 2000
        )
    }
}

private struct AcousticProbeMetadata: Encodable {
    let probe_version: Int
    let route: String
    let speaker_offset_cm: Double
    let microphone_offset_cm: Double
    let direct_path_cm: Double
    let neck_length_cm: Double?
    let temperature_c: Double

    init(
        probeVersion: Int,
        route: String,
        speakerOffsetCM: Double,
        microphoneOffsetCM: Double,
        directPathCM: Double,
        neckLengthCM: Double?,
        temperatureC: Double
    ) {
        self.probe_version = probeVersion
        self.route = route
        self.speaker_offset_cm = speakerOffsetCM
        self.microphone_offset_cm = microphoneOffsetCM
        self.direct_path_cm = directPathCM
        self.neck_length_cm = neckLengthCM
        self.temperature_c = temperatureC
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
                        Text("Estimated remaining")
                            .foregroundColor(.gray)
                        Spacer()
                        Text("≈ \(Int(result.remainingML.rounded())) ml")
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

                    if let repeats = result.acceptedAcousticRepeats,
                       let echoSNR = result.echoSNRDB {
                        HStack {
                            Text("Acoustic checks")
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(repeats) echoes · \(echoSNR, format: .number.precision(.fractionLength(1))) dB SNR")
                                .font(.caption)
                                .bold()
                        }
                    }

                    if let frequency = result.resonanceFrequencyHz {
                        HStack {
                            Text("Resonance")
                                .foregroundColor(.gray)
                            Spacer()
                            Text(String(format: "%.0f Hz", frequency))
                                .font(.caption)
                                .bold()
                        }
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

private extension UIImage {
    /// Make the displayed photo and the JPEG sent to the server share the
    /// same upright pixel coordinate system. Camera JPEGs can otherwise carry
    /// a portrait orientation tag while their raw pixels remain landscape,
    /// shifting manually selected circles on the backend.
    func normalizedForMeasurement() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
