import SwiftUI
import RealityKit
import ARKit

/// Compact AR height measurement: anchor the base on a surface, then project the top vertically.
struct ARHeightMeasurementView: View {
    @Binding var measuredHeightCM: Double?
    var onComplete: () -> Void

    @State private var topPoint: SIMD3<Float>?
    @State private var bottomPoint: SIMD3<Float>?
    @State private var currentStep: MeasureStep = .tapBottom
    @State private var arSessionState: ARTrackingState = .initializing
    @State private var measurementError: String?

    enum MeasureStep { case tapBottom, tapTop, done }

    var body: some View {
        ZStack {
            ARViewRepresentable(
                onTap: handleARTap,
                onTapFailure: { measurementError = $0 },
                onSessionStateChange: { arSessionState = $0 },
                topPoint: topPoint,
                bottomPoint: bottomPoint,
                verticalMeasurementBase: currentStep == .tapTop ? bottomPoint : nil,
                horizontalPlaneOnly: true
            )
            .ignoresSafeArea()

            VStack {
                if arSessionState != .ready {
                    Label(
                        arSessionState == .limited ? "緩慢移動手機，讓鏡頭辨識桌面" : "正在辨識平面…",
                        systemImage: "viewfinder"
                    )
                        .font(.fluxFont(.caption)).bold()
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.top, 8)
                }

                Spacer()

                VStack(spacing: 12) {
                    switch currentStep {
                    case .tapBottom:
                        Text("點選水瓶底部中心")
                            .font(.fluxFont(.headline)).bold()
                        Text("保持水瓶直立，點選它與桌面接觸的位置。")
                            .font(.fluxFont(.caption)).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    case .tapTop:
                        Text("點選瓶口中心")
                            .font(.fluxFont(.headline)).bold()
                        Text("盡量保持手機位置，點選瓶口中央。")
                            .font(.fluxFont(.caption)).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    case .done:
                        if let h = measuredHeightCM {
                            Text("瓶高 \(String(format: "%.1f", h)) cm")
                                .font(.fluxFont(.title2)).bold()
                                .foregroundColor(FluxTheme.accent)
                        }
                        Button("繼續") { onComplete() }
                            .buttonStyle(.borderedProminent)
                            .tint(FluxTheme.accent)
                    }

                    if let measurementError {
                        Text(measurementError)
                            .font(.fluxFont(.caption))
                            .foregroundStyle(.red)
                    }

                    if currentStep != .tapBottom {
                        Button("重新量測", action: resetMeasurement)
                            .font(.fluxFont(.caption, weight: .bold))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private func handleARTap(worldPosition: SIMD3<Float>) {
        switch currentStep {
        case .tapBottom:
            bottomPoint = worldPosition
            measurementError = nil
            withAnimation { currentStep = .tapTop }
        case .tapTop:
            guard let bottom = bottomPoint else {
                currentStep = .tapBottom
                return
            }
            let height = Double(abs(worldPosition.y - bottom.y)) * 100
            guard (5...100).contains(height) else {
                measurementError = "量測高度超出範圍，請重新點選瓶口。"
                return
            }
            topPoint = worldPosition
            measurementError = nil
            measuredHeightCM = height
            withAnimation { currentStep = .done }
        case .done:
            break
        }
    }

    private func resetMeasurement() {
        topPoint = nil
        bottomPoint = nil
        measuredHeightCM = nil
        measurementError = nil
        withAnimation { currentStep = .tapBottom }
    }
}
