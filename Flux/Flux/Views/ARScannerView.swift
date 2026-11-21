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
    @State private var scanReview: WaterScanReview? = nil
    @State private var showReviewSheet = false
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
                        if scenePhase == .active && !showBottleSelector && !showBottleProfileScanner && !showScanHelp && !showReviewSheet && !showError {
                            CalibratedWaterCameraView(
                                hasBottle: activeBottle != nil,
                                bottleOpeningDiameterCM: activeBottle?.diameterCM
                            ) { capture in
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
                Text("將瓶口內緣對齊圓框並保持水平，鎖定外框後會自動對焦瓶內水面，拍攝後可直接確認或調整水面圈。")
            }
            .sheet(isPresented: $showReviewSheet) {
                if let review = scanReview, let bottle = scanBottle, let capture = calibratedCapture {
                    let selectedRawImage: UIImage = {
                        let idx = review.selectedFocusIndex
                        if idx > 0, idx <= capture.focusFrames.count {
                            return capture.focusFrames[idx - 1].image
                        }
                        return capture.image
                    }()
                    WaterSurfaceReviewSheet(
                        review: review,
                        bottle: bottle,
                        baseSensorImage: selectedRawImage,
                        onConfirm: { result in
                            applyScanResult(result, bottle: bottle)
                            showReviewSheet = false
                            scanReview = nil
                        },
                        onRetake: {
                            showReviewSheet = false
                            scanReview = nil
                        }
                    )
                    .presentationDetents([.large])
                    .interactiveDismissDisabled(true)
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

            let review = try await apiManager.scanWaterVolumeForReview(
                capture: capture,
                bottle: bottle,
                lastRemainingML: previousRemaining,
                secondsSinceLastScan: previousScanAge
            )
            await MainActor.run {
                guard scanIsCurrent(bottle) else {
                    errorMessage = "量測期間瓶子資料已變更，請重新拍攝。"
                    showError = true
                    return
                }
                scanReview = review
                showReviewSheet = true
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

// MARK: - Interactive Water Surface Review & Adjustment Sheet
struct WaterSurfaceReviewSheet: View {
    let review: WaterScanReview
    let bottle: BottleProfile
    let baseSensorImage: UIImage
    let onConfirm: (WaterScanResult) -> Void
    let onRetake: () -> Void

    @Environment(WaterAPIManager.self) private var apiManager

    @State private var selectedCandidateIndex: Int?
    @State private var selectedRadiusPx: Double
    @State private var waterCenterDisp: CGPoint
    @State private var isManuallyAdjusted: Bool
    @State private var zoomed = false
    @State private var adjustingCenter = false
    @State private var confirming = false
    @State private var confirmError: String?

    private let transform: SensorDisplayTransform
    private let rimCenterDisp: CGPoint
    private let uprightImage: UIImage

    init(
        review: WaterScanReview,
        bottle: BottleProfile,
        baseSensorImage: UIImage,
        onConfirm: @escaping (WaterScanResult) -> Void,
        onRetake: @escaping () -> Void
    ) {
        self.review = review
        self.bottle = bottle
        self.baseSensorImage = baseSensorImage
        self.onConfirm = onConfirm
        self.onRetake = onRetake

        let xform = SensorDisplayTransform(
            rawWidth: Double(review.rawImageWidth),
            rawHeight: Double(review.rawImageHeight)
        )
        self.transform = xform
        let rimDisp = xform.toDisplay(CGPoint(x: review.outerCenterX, y: review.outerCenterY))
        self.rimCenterDisp = rimDisp

        if let cg = review.reviewImage.cgImage {
            self.uprightImage = UIImage(cgImage: cg, scale: 1, orientation: .right)
        } else {
            self.uprightImage = review.reviewImage
        }

        let initialIdx = review.recommendedCandidateIndex
        if let idx = initialIdx, idx < review.candidates.count {
            let cand = review.candidates[idx]
            _selectedCandidateIndex = State(initialValue: idx)
            _selectedRadiusPx = State(initialValue: cand.radiusPx)
            _waterCenterDisp = State(initialValue: xform.toDisplay(CGPoint(x: cand.centerX, y: cand.centerY)))
            _isManuallyAdjusted = State(initialValue: review.autoResult == nil)
        } else {
            _selectedCandidateIndex = State(initialValue: nil)
            _selectedRadiusPx = State(initialValue: review.outerRadiusPx * 0.56)
            _waterCenterDisp = State(initialValue: rimDisp)
            _isManuallyAdjusted = State(initialValue: true)
        }
    }

    private var minRadiusPx: Double { max(12.0, review.outerRadiusPx * 0.20) }
    private var maxRadiusPx: Double { max(minRadiusPx + 4.0, review.outerRadiusPx * 0.94) }

    private var liveLevel: (heightCM: Double, depthCM: Double, remainingML: Double)? {
        if let idx = selectedCandidateIndex, idx < review.candidates.count {
            let cand = review.candidates[idx]
            if let ml = cand.remainingVolumeML,
               let h = cand.waterHeightCM,
               let d = cand.waterDepthCM,
               abs(cand.radiusPx - selectedRadiusPx) < 0.5 {
                return (h, d, ml)
            }
        }
        return WaterCaptureGeometry.solveWaterLevel(
            profileHeightsCM: review.reconciledHeightsCM,
            profileRadiiCM: review.reconciledRadiiCM,
            bottleHeightCM: bottle.heightCM,
            capacityML: bottle.totalVolumeMl,
            distanceCM: review.phoneToRimCM,
            focalLengthPx: review.focalLengthPx,
            observedRadiusPx: selectedRadiusPx
        )
    }

    private var liveConsumedML: Double? {
        guard let baseline = review.lastRemainingBaselineML,
              let current = liveLevel?.remainingML,
              baseline > current else { return nil }
        return baseline - current
    }

    private var selectionModeLabel: String {
        if let idx = selectedCandidateIndex, idx < review.candidates.count {
            if idx == review.recommendedCandidateIndex && review.autoResult != nil && !isManuallyAdjusted {
                return "模型自動偵測"
            }
            if idx == review.recommendedCandidateIndex {
                return "模型建議層"
            }
            return "候選層 #\(idx + 1)"
        }
        return "手動對齊水面"
    }

    var body: some View {
        ZStack {
            FluxTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button("重拍") {
                        onRetake()
                    }
                    .font(.geist(.subheadline, weight: .semibold))
                    .foregroundColor(.gray)
                    .disabled(confirming)

                    Spacer()

                    VStack(spacing: 2) {
                        Text("確認水面位置")
                            .font(.geist(.headline, weight: .bold))
                            .foregroundColor(.white)
                        Text(bottle.name)
                            .font(.geist(.caption))
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            zoomed.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass")
                                .font(.system(size: 12, weight: .semibold))
                            Text(zoomed ? "1x" : "放大")
                                .font(.geist(.caption, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        interactiveCanvas

                        // Compact legend & center-adjust toggle
                        HStack(spacing: 10) {
                            Label("瓶口(已鎖定)", systemImage: "circle.fill")
                                .font(.geist(.caption2, weight: .medium))
                                .foregroundColor(.green)
                            Label("水面", systemImage: "circle.fill")
                                .font(.geist(.caption2, weight: .medium))
                                .foregroundColor(.orange)
                            Spacer()
                            Button {
                                adjustingCenter.toggle()
                            } label: {
                                Text(adjustingCenter ? "完成圓心" : "微調圓心")
                                    .font(.geist(.caption2, weight: .semibold))
                                    .foregroundColor(adjustingCenter ? .black : .white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        adjustingCenter ? Color.orange : Color.white.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                            if hypot(waterCenterDisp.x - rimCenterDisp.x, waterCenterDisp.y - rimCenterDisp.y) > 2 {
                                Button("置中") {
                                    waterCenterDisp = rimCenterDisp
                                    selectedCandidateIndex = nil
                                    isManuallyAdjusted = true
                                }
                                .font(.geist(.caption2, weight: .semibold))
                                .foregroundColor(.cyan)
                            }
                        }
                        .padding(.horizontal, 16)

                        // Model candidate quick-pick chips
                        if !review.candidates.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("模型偵測到的水面候選（點選即可切換）")
                                    .font(.geist(.caption, weight: .medium))
                                    .foregroundColor(.gray)
                                    .padding(.horizontal, 16)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(Array(review.candidates.enumerated()), id: \.element.id) { idx, cand in
                                            candidateChip(index: idx, candidate: cand)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "hand.point.up.left.fill")
                                    .foregroundColor(.orange)
                                Text("未自動辨識出單一水面，請直接點選照片上的水面邊緣或拖曳滑桿對齊橘框。")
                                    .font(.geist(.caption))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 16)
                        }

                        // Precision radius slider
                        VStack(spacing: 6) {
                            HStack {
                                Text("微調水面圓框")
                                    .font(.geist(.caption, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                                Spacer()
                                Text("\(selectionModeLabel) · \(Int((selectedRadiusPx / max(review.outerRadiusPx, 1)) * 100))%")
                                    .font(.geist(.caption))
                                    .foregroundColor(.orange)
                            }

                            HStack(spacing: 10) {
                                Button {
                                    nudgeRadius(-3)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(.white.opacity(0.75))
                                }

                                Slider(
                                    value: Binding(
                                        get: { min(maxRadiusPx, max(minRadiusPx, selectedRadiusPx)) },
                                        set: { newValue in
                                            selectedRadiusPx = newValue
                                            selectedCandidateIndex = nil
                                            isManuallyAdjusted = true
                                        }
                                    ),
                                    in: minRadiusPx...maxRadiusPx
                                )
                                .tint(.orange)

                                Button {
                                    nudgeRadius(3)
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(.white.opacity(0.75))
                                }
                            }
                        }
                        .padding(14)
                        .fluxCard(cornerRadius: 16)
                        .padding(.horizontal, 16)

                        // Live estimated volume card
                        VStack(spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("估計剩餘水量")
                                    .font(.geist(.subheadline))
                                    .foregroundColor(.gray)
                                Spacer()
                                if let level = liveLevel {
                                    Text("≈ \(Int(level.remainingML.rounded())) ml")
                                        .font(.geist(size: 26, relativeTo: .title2, weight: .bold))
                                        .foregroundColor(FluxTheme.accent)
                                } else {
                                    Text("此半徑無法唯一對應水位")
                                        .font(.geist(.subheadline, weight: .semibold))
                                        .foregroundColor(.orange)
                                }
                            }

                            if let level = liveLevel {
                                HStack {
                                    Text("水深 \(String(format: "%.1f", level.depthCM)) cm · 水位高 \(String(format: "%.1f", level.heightCM)) cm")
                                        .font(.geist(.caption))
                                        .foregroundColor(.gray)
                                    Spacer()
                                    if let drank = liveConsumedML, drank >= 1 {
                                        Text("本次飲用 ≈ \(Int(drank.rounded())) ml")
                                            .font(.geist(.caption, weight: .semibold))
                                            .foregroundColor(.green)
                                    } else if review.lastRemainingBaselineML == nil {
                                        Text("首次掃描基準")
                                            .font(.geist(.caption))
                                            .foregroundColor(.gray)
                                    }
                                }
                            }

                            if let confirmError {
                                Text(confirmError)
                                    .font(.geist(.caption))
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(14)
                        .fluxCard(cornerRadius: 16)
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 16)
                }

                // Bottom CTA bar
                HStack(spacing: 12) {
                    Button {
                        onRetake()
                    } label: {
                        Text("重拍")
                            .font(.geist(.headline, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(confirming)

                    Button {
                        Task { await confirmSelection() }
                    } label: {
                        HStack(spacing: 8) {
                            if confirming {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.85)
                            }
                            Text(confirmButtonTitle)
                                .font(.geist(.headline, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            (liveLevel != nil && !confirming) ? FluxTheme.accent : Color.gray.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                    }
                    .disabled(liveLevel == nil || confirming)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 18)
                .background(FluxTheme.background.opacity(0.95))
            }
        }
    }

    private var confirmButtonTitle: String {
        if confirming { return "計算中…" }
        if let drank = liveConsumedML, drank >= 1 {
            return "確認並記錄 (-\(Int(drank.rounded())) ml)"
        }
        return "確認並保存"
    }

    @ViewBuilder
    private var interactiveCanvas: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            let rimR = max(review.outerRadiusPx, 1)
            let viewHalfSpan = rimR * (zoomed ? 1.04 : 1.24)
            let ptPerPx = side / (2 * viewHalfSpan)

            let toCanvas: (CGPoint) -> CGPoint = { disp in
                CGPoint(
                    x: side / 2 + (disp.x - rimCenterDisp.x) * ptPerPx,
                    y: side / 2 + (disp.y - rimCenterDisp.y) * ptPerPx
                )
            }
            let fromCanvas: (CGPoint) -> CGPoint = { pt in
                CGPoint(
                    x: rimCenterDisp.x + (pt.x - side / 2) / ptPerPx,
                    y: rimCenterDisp.y + (pt.y - side / 2) / ptPerPx
                )
            }

            let imageCenterCanvas = toCanvas(
                CGPoint(x: transform.displayWidth / 2, y: transform.displayHeight / 2)
            )
            let rimCanvasCenter = toCanvas(rimCenterDisp)
            let waterCanvasCenter = toCanvas(waterCenterDisp)
            let rimDisplayDiameter = rimR * 2 * ptPerPx
            let waterDisplayDiameter = selectedRadiusPx * 2 * ptPerPx

            ZStack {
                Color.black

                Image(uiImage: uprightImage)
                    .resizable()
                    .frame(
                        width: transform.displayWidth * ptPerPx,
                        height: transform.displayHeight * ptPerPx
                    )
                    .position(imageCenterCanvas)

                // Locked green bottle rim
                Circle()
                    .stroke(Color.green, lineWidth: 2.5)
                    .frame(width: rimDisplayDiameter, height: rimDisplayDiameter)
                    .position(rimCanvasCenter)

                // Secondary detected candidate rings (dashed cyan)
                ForEach(Array(review.candidates.enumerated()), id: \.element.id) { idx, cand in
                    if idx != selectedCandidateIndex {
                        let cDisp = transform.toDisplay(CGPoint(x: cand.centerX, y: cand.centerY))
                        let cCanvas = toCanvas(cDisp)
                        let cRadiusPt = cand.radiusPx * ptPerPx
                        Circle()
                            .stroke(
                                cand.likelyBase ? Color.white.opacity(0.32) : Color.cyan.opacity(0.60),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                            )
                            .frame(width: cRadiusPt * 2, height: cRadiusPt * 2)
                            .position(cCanvas)

                        Text("#\(idx + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                cand.likelyBase ? Color.white.opacity(0.65) : Color.cyan.opacity(0.9),
                                in: Capsule()
                            )
                            .position(x: cCanvas.x, y: max(14, cCanvas.y - cRadiusPt))
                    }
                }

                // Active orange water surface ring
                Circle()
                    .stroke(Color.orange.opacity(0.30), lineWidth: 8)
                    .frame(width: waterDisplayDiameter, height: waterDisplayDiameter)
                    .position(waterCanvasCenter)
                Circle()
                    .stroke(Color.orange, lineWidth: 2.75)
                    .frame(width: waterDisplayDiameter, height: waterDisplayDiameter)
                    .position(waterCanvasCenter)

                if adjustingCenter {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.orange)
                        .position(waterCanvasCenter)
                }

                // Top status badges inside canvas
                VStack {
                    HStack {
                        if review.focusStackCount > 1 {
                            HStack(spacing: 4) {
                                Image(systemName: "camera.aperture")
                                    .font(.system(size: 10, weight: .bold))
                                if let lp = review.selectedLensPosition {
                                    Text(String(format: "銳利對焦 · 焦段 %.2f", lp))
                                        .font(.geist(.caption2, weight: .semibold))
                                } else {
                                    Text("單張對焦 \(review.selectedFocusIndex + 1)/\(review.focusStackCount)")
                                        .font(.geist(.caption2, weight: .semibold))
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.68), in: Capsule())
                        }
                        Spacer()
                        Text(adjustingCenter ? "拖曳移動水面圓心" : "點選或拖曳水面邊緣")
                            .font(.geist(.caption2, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.65), in: Capsule())
                    }
                    .padding(10)
                    Spacer()
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let touchedDisp = fromCanvas(value.location)
                        if adjustingCenter {
                            let dx = touchedDisp.x - rimCenterDisp.x
                            let dy = touchedDisp.y - rimCenterDisp.y
                            let maxShift = rimR * 0.13
                            let dist = hypot(dx, dy)
                            let factor = dist > maxShift ? maxShift / dist : 1.0
                            waterCenterDisp = CGPoint(
                                x: rimCenterDisp.x + dx * factor,
                                y: rimCenterDisp.y + dy * factor
                            )
                            selectedCandidateIndex = nil
                            isManuallyAdjusted = true
                        } else if hypot(value.translation.width, value.translation.height) >= 5 {
                            let distPx = hypot(touchedDisp.x - waterCenterDisp.x, touchedDisp.y - waterCenterDisp.y)
                            selectedRadiusPx = min(maxRadiusPx, max(minRadiusPx, distPx))
                            selectedCandidateIndex = nil
                            isManuallyAdjusted = true
                        }
                    }
                    .onEnded { value in
                        guard !adjustingCenter else { return }
                        let travel = hypot(value.translation.width, value.translation.height)
                        let touchedDisp = fromCanvas(value.location)
                        if travel < 8 {
                            // Snap to a nearby candidate ring if tapped close to its edge.
                            var snapped: Int?
                            var bestDelta = 18.0 / ptPerPx
                            for (idx, cand) in review.candidates.enumerated() {
                                let cDisp = transform.toDisplay(CGPoint(x: cand.centerX, y: cand.centerY))
                                let d = hypot(touchedDisp.x - cDisp.x, touchedDisp.y - cDisp.y)
                                let delta = abs(d - cand.radiusPx)
                                if delta < bestDelta {
                                    bestDelta = delta
                                    snapped = idx
                                }
                            }
                            if let idx = snapped {
                                selectCandidate(idx)
                                return
                            }
                        }
                        let distPx = hypot(touchedDisp.x - waterCenterDisp.x, touchedDisp.y - waterCenterDisp.y)
                        selectedRadiusPx = min(maxRadiusPx, max(minRadiusPx, distPx))
                        selectedCandidateIndex = nil
                        isManuallyAdjusted = true
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func candidateChip(index: Int, candidate: WaterSurfaceCandidate) -> some View {
        let isSelected = selectedCandidateIndex == index
        let title: String = {
            if index == review.recommendedCandidateIndex { return "★ 模型建議" }
            if candidate.likelyBase { return "較深層 #\(index + 1)" }
            return "候選 #\(index + 1)"
        }()
        let mlText = candidate.remainingVolumeML.map { "\(Int($0.rounded())) ml" } ?? "—"

        Button {
            selectCandidate(index)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.geist(.caption, weight: .semibold))
                Text(mlText)
                    .font(.geist(.caption, weight: .bold))
            }
            .foregroundColor(isSelected ? .black : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.orange : Color.white.opacity(0.10),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.orange : Color.white.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func selectCandidate(_ index: Int) {
        guard index < review.candidates.count else { return }
        let cand = review.candidates[index]
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        selectedCandidateIndex = index
        selectedRadiusPx = cand.radiusPx
        waterCenterDisp = transform.toDisplay(CGPoint(x: cand.centerX, y: cand.centerY))
        isManuallyAdjusted = !(review.autoResult != nil && index == review.recommendedCandidateIndex)
        confirmError = nil
    }

    private func nudgeRadius(_ deltaPx: Double) {
        selectedRadiusPx = min(maxRadiusPx, max(minRadiusPx, selectedRadiusPx + deltaPx))
        selectedCandidateIndex = nil
        isManuallyAdjusted = true
        confirmError = nil
    }

    @MainActor
    private func confirmSelection() async {
        confirmError = nil
        // Fast path: user confirmed the model's auto-accepted result without edits.
        if let auto = review.autoResult,
           !isManuallyAdjusted,
           selectedCandidateIndex == review.recommendedCandidateIndex {
            onConfirm(auto)
            return
        }

        confirming = true
        defer { confirming = false }
        let waterRaw = transform.toRaw(waterCenterDisp)

        do {
            let result = try await apiManager.confirmManualWaterCircle(
                image: baseSensorImage,
                bottle: bottle,
                outerCenter: CGPoint(x: review.outerCenterX, y: review.outerCenterY),
                outerRadiusPx: review.outerRadiusPx,
                innerCenter: waterRaw,
                innerRadiusPx: selectedRadiusPx,
                focalLengthPx: review.focalLengthPx,
                imuAlignmentScore: review.imuAlignmentScore,
                lastRemainingML: review.lastRemainingBaselineML,
                secondsSinceLastScan: review.previousScanAgeSeconds
            )
            onConfirm(result)
        } catch {
            confirmError = error.localizedDescription
        }
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
