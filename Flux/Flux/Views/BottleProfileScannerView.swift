import SwiftUI
import SwiftData
import UIKit

/// Creates a bottle model from one side photo and an AR height measurement.
struct BottleProfileScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allBottles: [BottleProfile]

    @State private var step: SetupStep = .capture
    @State private var showCamera = false
    @State private var capturedImage: UIImage?
    @State private var overlayImage: UIImage?
    @State private var rawProfile: [CGPoint] = []
    @State private var appearance = BottleAppearance.fallback
    @State private var fittedProfile: BottleVolumeCalculator.CapacityFittedProfile?
    @State private var measuredHeightCM: Double?
    @State private var detectedCapacityML: Int?
    @State private var isProcessing = false

    @State private var bottleName = "我的水瓶"
    @State private var bottleCapacityML = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @AppStorage("flux_show_diagnostics") private var showDiagnostics = false

    enum SetupStep {
        case capture
        case measure
        case review
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .capture:
                    captureStep
                case .measure:
                    measurementStep
                case .review:
                    reviewStep
                }
            }
            .background(FluxTheme.background.ignoresSafeArea())
            .navigationTitle("新增水瓶")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(step == .capture ? "取消" : "返回") {
                        if step == .capture {
                            dismiss()
                        } else {
                            withAnimation { step = step == .review ? .measure : .capture }
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
            .alert("無法建立水瓶", isPresented: $showError) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var measurementStep: some View {
        ARHeightMeasurementView(measuredHeightCM: $measuredHeightCM) {
            rebuildModel()
            withAnimation { step = .review }
        }
    }

    private var captureStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                stepIndicator

                VStack(spacing: 8) {
                    Text("拍攝水瓶側面")
                        .font(.fluxFont(.title2, weight: .bold))
                    Text("將水瓶直立放在單純背景前，讓瓶口到瓶底完整入鏡。")
                        .font(.fluxFont(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(FluxTheme.surface)

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
                            Text("讓水瓶置中並保持直立")
                                .font(.fluxFont(.caption))
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
                            Text("正在建立水瓶輪廓…")
                                .font(.fluxFont(.subheadline, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(height: 390)
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    captureTip(icon: "rectangle.portrait", text: "水瓶完整入鏡")
                    captureTip(icon: "waterbottle", text: "打開瓶蓋，讓瓶口清楚可見")
                    captureTip(icon: "light.max", text: "使用均勻光線，避免強烈陰影")
                    captureTip(icon: "hand.raised.slash", text: "拍照時不要遮住瓶身")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)

                Button {
                    capturedImage = nil
                    overlayImage = nil
                    measuredHeightCM = nil
                    detectedCapacityML = nil
                    showCamera = true
                } label: {
                    Label(capturedImage == nil ? "拍攝水瓶" : "重新拍攝", systemImage: "camera.fill")
                        .font(.fluxFont(.headline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(FluxTheme.accent)
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
                            .font(.fluxFont(.headline))
                            .foregroundStyle(qualityColor)
                        Text(qualityDetail)
                            .font(.fluxFont(.caption))
                            .foregroundStyle(.secondary)

                        Button("重新拍攝") {
                            withAnimation { step = .capture }
                        }
                        .font(.fluxFont(.subheadline, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .fluxCard()
                .padding(.horizontal)

                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("水瓶名稱")
                            .font(.fluxFont(.caption, weight: .bold))
                            .foregroundStyle(.secondary)
                        TextField("我的水瓶", text: $bottleName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("標示容量")
                            .font(.fluxFont(.caption, weight: .bold))
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("輸入瓶身標示容量", text: $bottleCapacityML)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                            Text("ml")
                                .foregroundStyle(.secondary)
                        }
                        Text("容量用來校正估算結果，不代表已量到瓶身內部形狀。")
                            .font(.fluxFont(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .fluxCard()
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("水瓶預覽", systemImage: "cube.transparent")
                            .font(.fluxFont(.headline))
                        Spacer()
                        if showDiagnostics, let fittedProfile {
                            Text("幾何估值 ≈ \(Int(fittedProfile.computedVolumeML.rounded())) ml")
                                .font(.fluxFont(.subheadline, weight: .bold))
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

                    if let capacityEstimate {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(capacityEstimate.detectedLabelCapacityML == nil ? "建議容量" : "辨識到的標示容量")
                                .font(.fluxFont(.caption, weight: .bold))
                                .foregroundStyle(.secondary)
                            HStack {
                                ForEach(capacityEstimate.suggestedCapacitiesML, id: \.self) { value in
                                    Button("\(value) ml") {
                                        bottleCapacityML = "\(value)"
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            Text("參考範圍：\(capacityEstimate.lowerBoundML)–\(capacityEstimate.upperBoundML) ml")
                                .font(.fluxFont(.caption2))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let fittedProfile {
                        HStack {
                            modelMetric("水瓶高度", value: String(format: "%.1f cm", fittedProfile.heightCM))
                            Divider().frame(height: 34)
                            let widestDiameter = (fittedProfile.physical.map(\.radius).max() ?? 0) * 2
                            modelMetric("最大直徑", value: String(format: "%.1f cm", widestDiameter))
                        }
                    }
                }
                .padding()
                .fluxCard()
                .padding(.horizontal)

                Button(action: saveProfile) {
                    Text("儲存水瓶")
                        .font(.fluxFont(.headline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(FluxTheme.accent)
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
            stepBadge(number: 1, title: "拍照", active: step == .capture)
            Capsule()
                .fill(step != .capture ? Color.blue : Color.secondary.opacity(0.2))
                .frame(height: 3)
            stepBadge(number: 2, title: "量高度", active: step == .measure)
            Capsule()
                .fill(step == .review ? Color.blue : Color.secondary.opacity(0.2))
                .frame(height: 3)
            stepBadge(number: 3, title: "確認", active: step == .review)
        }
        .padding(.horizontal, 20)
    }

    private func stepBadge(number: Int, title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.fluxFont(.caption, weight: .bold))
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: 24, height: 24)
                .background(active ? Color.blue : Color.secondary.opacity(0.15))
                .clipShape(Circle())
            Text(title)
                .font(.fluxFont(.caption, weight: .bold))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private func captureTip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.fluxFont(.subheadline))
            .foregroundStyle(.secondary)
    }

    private func modelMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.fluxFont(.subheadline, weight: .bold))
            Text(title).font(.fluxFont(.caption2)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var displayProfile: [CGPoint] {
        guard let fittedProfile else { return [] }
        let points = fittedProfile.physical.map { CGPoint(x: $0.radius, y: $0.height) }
        return BottleMeshGenerator.normalizeProfileForDisplay(points)
    }

    private var capacity: Double? {
        guard let value = Double(bottleCapacityML), (100...5000).contains(value) else { return nil }
        return value
    }

    private var capacityEstimate: BottleVolumeCalculator.CapacityEstimate? {
        guard let fittedProfile else { return nil }
        return BottleVolumeCalculator.estimateCapacity(
            geometricVolumeML: fittedProfile.computedVolumeML,
            qualityScore: fittedProfile.qualityScore,
            detectedLabelCapacityML: detectedCapacityML
        )
    }

    private var canSave: Bool {
        fittedProfile != nil
            && (fittedProfile?.qualityScore ?? 0) >= 0.45
            && measuredHeightCM != nil
            && capacity != nil
            && !bottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var qualityTitle: String {
        switch fittedProfile?.qualityScore ?? 0 {
        case 0.82...: return "輪廓清楚"
        case 0.65...: return "輪廓可用"
        case 0.45...: return "建議檢查輪廓"
        default: return "建議重新拍攝"
        }
    }

    private var qualityDetail: String {
        switch fittedProfile?.qualityScore ?? 0 {
        case 0.82...: return "瓶身輪廓完整，可以繼續。"
        case 0.65...: return "模型已可使用；單純背景能讓輪廓更清楚。"
        case 0.45...: return "可以儲存，但重新置中拍攝通常更可靠。"
        default: return "輪廓不完整或變形，請讓整個水瓶入鏡。"
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
                    rawProfile = result.rawProfile
                    overlayImage = result.overlayImage
                    appearance = result.appearance
                    detectedCapacityML = result.detectedCapacityML
                    isProcessing = false
                    withAnimation { step = .measure }
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

    private func rebuildModel() {
        guard let measuredHeightCM else {
            fittedProfile = nil
            return
        }
        fittedProfile = BottleVolumeCalculator.fitProfileToMeasuredHeight(
            rawPoints: rawProfile,
            heightCM: measuredHeightCM
        )
    }

    private func saveProfile() {
        guard let capacity,
              let fittedProfile,
              fittedProfile.qualityScore >= 0.45 else {
            errorMessage = "請輸入 100–5000 ml 的容量，並重新拍攝清楚的水瓶照片。"
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
            errorMessage = "無法儲存水瓶：\(error.localizedDescription)"
            showError = true
        }
    }
}
