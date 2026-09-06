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
                        arSessionState == .limited ? "Move the phone slowly around the bottle" : "Scanning surfaces…",
                        systemImage: "viewfinder"
                    )
                        .font(.caption).bold()
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.top, 8)
                }

                Spacer()

                VStack(spacing: 12) {
                    switch currentStep {
                    case .tapBottom:
                        Text("Tap the bottom centre of your bottle")
                            .font(.headline).bold()
                        Text("Keep the bottle upright and tap where it meets the table or floor.")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    case .tapTop:
                        Text("Tap the top centre of your bottle")
                            .font(.headline).bold()
                        Text("Keep the phone in place and tap the centre of the bottle opening.")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    case .done:
                        if let h = measuredHeightCM {
                            Text("Height: \(String(format: "%.1f", h)) cm")
                                .font(.title2).bold()
                                .foregroundColor(.blue)
                        }
                        Button("Continue") { onComplete() }
                            .buttonStyle(.borderedProminent)
                    }

                    if let measurementError {
                        Text(measurementError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if currentStep != .tapBottom {
                        Button("Start over", action: resetMeasurement)
                            .font(.caption.bold())
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
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
                measurementError = "That measurement looks invalid. Tap the bottle top again."
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
