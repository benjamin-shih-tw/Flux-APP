import SwiftUI
import AVFoundation
import SwiftData
import UIKit

// MARK: - Main AR Scanner View
struct ARScannerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager
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
    @State private var showCircleSelection = false
    @State private var capturedImage: UIImage? = nil
    @State private var scanResult: WaterScanResult? = nil
    @State private var showResultSheet = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showBottleSelector = false
    @State private var showBottleProfileScanner = false
    @State private var isAcousticCapturing = false
    @State private var acousticCaptureManager = AcousticCaptureManager()

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
                                if apiManager.isLoading || isAcousticCapturing {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: activeBottle == nil ? "plus" : (alignmentMonitor.captureReady ? "camera.fill" : "lock.fill"))
                                        .font(.system(size: 28))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .disabled(apiManager.isLoading || isAcousticCapturing)

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
                            // Give the user a chance to correct the two
                            // circles before any volume calculation begins.
                            capturedImage = img.normalizedForMeasurement()
                            // Presenting a second sheet synchronously from
                            // the camera sheet's dismissal can be dropped by
                            // UIKit. Defer one run-loop turn so the camera is
                            // fully gone first.
                            DispatchQueue.main.async {
                                showCircleSelection = true
                            }
                        }
                    }
            }
            .sheet(isPresented: $showCircleSelection) {
                if let image = capturedImage {
                    CircleSelectionView(image: image) { selection in
                        showCircleSelection = false
                        Task { await sendImageToAPI(image, manualCircles: selection) }
                    } onCancel: {
                        showCircleSelection = false
                        capturedImage = nil
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
    @MainActor
    private func sendImageToAPI(_ image: UIImage, manualCircles: ManualCircleSelection? = nil) async {
        guard let bottle = activeBottle else { return }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        let focalLengthPixels = estimatedFocalLengthPixels(for: image)

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
                imuAlignmentScore: alignmentMonitor.alignmentScore,
                lastRemainingML: previousRemaining,
                secondsSinceLastScan: previousScanAge,
                audioData: nil,
                acousticMetadataJSON: "{}",
                cameraFocalLengthPx: focalLengthPixels,
                phoneToRimCM: nil,
                surfaceMode: "auto",
                manualCircles: manualCircles
            )
            await MainActor.run {
                scanResult = result
                showResultSheet = true
            }
        } catch {
            isAcousticCapturing = false
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    /// Convert the active back-camera field of view into a focal length in the
    /// captured image's pixel coordinate system. A fixed iPhone focal length
    /// substantially overestimates depth for iPad photographs.
    private func estimatedFocalLengthPixels(for image: UIImage) -> Double? {
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            return nil
        }
        let fieldOfViewDegrees = Double(camera.activeFormat.videoFieldOfView)
        guard fieldOfViewDegrees > 1, fieldOfViewDegrees < 179 else {
            return nil
        }
        let sensorWidthPixels = Double(max(image.size.width, image.size.height) * image.scale)
        let halfAngleRadians = fieldOfViewDegrees * .pi / 360
        return sensorWidthPixels / (2 * tan(halfAngleRadians))
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

// MARK: - Manual measurement circle selection
private enum CircleSelectionTarget {
    case outer
    case inner
}

/// Lets the user correct the two measurement circles on the captured photo.
/// The model/profile setup flow is intentionally not involved here.
struct CircleSelectionView: View {
    let image: UIImage
    let onConfirm: (ManualCircleSelection) -> Void
    let onCancel: () -> Void

    @State private var target: CircleSelectionTarget = .outer
    @State private var outerCenter: CGPoint
    @State private var innerCenter: CGPoint
    @State private var outerRadius: CGFloat
    @State private var innerRadius: CGFloat

    init(
        image: UIImage,
        onConfirm: @escaping (ManualCircleSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.image = image
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _outerCenter = State(initialValue: CGPoint(x: 0.5, y: 0.5))
        _innerCenter = State(initialValue: CGPoint(x: 0.5, y: 0.5))
        _outerRadius = State(initialValue: 0.38)
        _innerRadius = State(initialValue: 0.24)
    }

    private var pixelWidth: CGFloat {
        CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
    }

    private var pixelHeight: CGFloat {
        CGFloat(image.cgImage?.height ?? Int(image.size.height * image.scale))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消", action: onCancel)
                    .foregroundColor(.red)
                Spacer()
                Text("校正測量圓")
                    .font(.headline)
                Spacer()
                Button("重新設定") {
                    outerCenter = CGPoint(x: 0.5, y: 0.5)
                    innerCenter = CGPoint(x: 0.5, y: 0.5)
                    outerRadius = 0.38
                    innerRadius = 0.24
                }
                .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Text("先選取瓶口，再選取水面；可拖曳圓心與圓邊調整")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)

            GeometryReader { proxy in
                let rect = imageRect(in: proxy.size)
                let displayScale = min(rect.width, rect.height)
                let outerDisplayRadius = outerRadius * displayScale
                let innerDisplayRadius = innerRadius * displayScale

                ZStack {
                    Color.black
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    setActiveCenter(normalized(value.location, in: rect))
                                }
                        )

                    Circle()
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .frame(width: outerDisplayRadius * 2, height: outerDisplayRadius * 2)
                        .position(displayPoint(outerCenter, in: rect))
                    Circle()
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .frame(width: innerDisplayRadius * 2, height: innerDisplayRadius * 2)
                        .position(displayPoint(innerCenter, in: rect))

                    centerHandle(
                        point: displayPoint(outerCenter, in: rect),
                        color: .green,
                        isActive: target == .outer
                    ) {
                        target = .outer
                    } onDrag: { location in
                        outerCenter = normalized(location, in: rect)
                    }
                    centerHandle(
                        point: displayPoint(innerCenter, in: rect),
                        color: .orange,
                        isActive: target == .inner
                    ) {
                        target = .inner
                    } onDrag: { location in
                        innerCenter = normalized(location, in: rect)
                    }

                    radiusHandle(
                        point: CGPoint(
                            x: displayPoint(outerCenter, in: rect).x + outerDisplayRadius,
                            y: displayPoint(outerCenter, in: rect).y
                        ),
                        color: .green
                    ) {
                        target = .outer
                    } onDrag: { location in
                        outerRadius = clampedRadius(
                            distance(location, displayPoint(outerCenter, in: rect)) / displayScale,
                            minimum: 0.08,
                            maximum: 0.49
                        )
                    }
                    radiusHandle(
                        point: CGPoint(
                            x: displayPoint(innerCenter, in: rect).x + innerDisplayRadius,
                            y: displayPoint(innerCenter, in: rect).y
                        ),
                        color: .orange
                    ) {
                        target = .inner
                    } onDrag: { location in
                        innerRadius = clampedRadius(
                            distance(location, displayPoint(innerCenter, in: rect)) / displayScale,
                            minimum: 0.03,
                            maximum: max(0.05, outerRadius * 0.94)
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }

            HStack(spacing: 10) {
                targetButton("瓶口圓", color: .green, selected: target == .outer) {
                    target = .outer
                }
                targetButton("水面圓", color: .orange, selected: target == .inner) {
                    target = .inner
                }
                Button {
                    adjustRadius(by: -0.02)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                Button {
                    adjustRadius(by: 0.02)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            .font(.title3)
            .padding(.top, 10)

            HStack {
                Label("綠色：瓶口", systemImage: "circle")
                    .foregroundColor(.green)
                Label("橘色：水面", systemImage: "circle")
                    .foregroundColor(.orange)
            }
            .font(.caption)
            .padding(.vertical, 6)

            Button {
                onConfirm(makeSelection())
            } label: {
                Text("使用選取結果計算")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .background(Color(UIColor.systemBackground))
    }

    private func imageRect(in size: CGSize) -> CGRect {
        let scale = min(size.width / max(pixelWidth, 1), size.height / max(pixelHeight, 1))
        let width = pixelWidth * scale
        let height = pixelHeight * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func displayPoint(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width, y: rect.minY + normalized.y * rect.height)
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(1, max(0, (point.x - rect.minX) / rect.width)),
            y: min(1, max(0, (point.y - rect.minY) / rect.height))
        )
    }

    private func setActiveCenter(_ point: CGPoint) {
        if target == .outer { outerCenter = point } else { innerCenter = point }
    }

    private func adjustRadius(by amount: CGFloat) {
        if target == .outer {
            outerRadius = clampedRadius(outerRadius + amount, minimum: 0.08, maximum: 0.49)
            innerRadius = min(innerRadius, outerRadius * 0.94)
        } else {
            innerRadius = clampedRadius(innerRadius + amount, minimum: 0.03, maximum: max(0.05, outerRadius * 0.94))
        }
    }

    private func clampedRadius(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func makeSelection() -> ManualCircleSelection {
        let scale = min(pixelWidth, pixelHeight)
        return ManualCircleSelection(
            outerCenterX: Double(outerCenter.x * pixelWidth),
            outerCenterY: Double(outerCenter.y * pixelHeight),
            outerRadiusPx: Double(outerRadius * scale),
            innerCenterX: Double(innerCenter.x * pixelWidth),
            innerCenterY: Double(innerCenter.y * pixelHeight),
            innerRadiusPx: Double(innerRadius * scale)
        )
    }

    @ViewBuilder
    private func targetButton(
        _ title: String,
        color: Color,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.subheadline.bold())
            .foregroundColor(selected ? .white : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? color : color.opacity(0.12))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func centerHandle(
        point: CGPoint,
        color: Color,
        isActive: Bool,
        onTap: @escaping () -> Void,
        onDrag: @escaping (CGPoint) -> Void
    ) -> some View {
        Circle()
            .fill(color.opacity(isActive ? 0.95 : 0.65))
            .frame(width: 38, height: 38)
            .overlay(Image(systemName: "move").foregroundColor(.white).font(.caption))
            .position(point)
            .onTapGesture(perform: onTap)
            .gesture(DragGesture().onChanged { value in
                onTap()
                onDrag(value.location)
            })
            .zIndex(3)
    }

    @ViewBuilder
    private func radiusHandle(
        point: CGPoint,
        color: Color,
        onTap: @escaping () -> Void,
        onDrag: @escaping (CGPoint) -> Void
    ) -> some View {
        Circle()
            .fill(color)
            .frame(width: 30, height: 30)
            .overlay(Image(systemName: "arrow.left.and.right").foregroundColor(.white).font(.caption2))
            .position(point)
            .onTapGesture(perform: onTap)
            .gesture(DragGesture().onChanged { value in
                onTap()
                onDrag(value.location)
            })
            .zIndex(4)
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
