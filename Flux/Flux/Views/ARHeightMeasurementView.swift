import SwiftUI
import RealityKit
import ARKit

/// Compact AR height measurement: tap bottle top rim, then bottom.
struct ARHeightMeasurementView: View {
    @Binding var measuredHeightCM: Double?
    var onComplete: () -> Void

    @State private var topPoint: SIMD3<Float>?
    @State private var bottomPoint: SIMD3<Float>?
    @State private var currentStep: MeasureStep = .tapTop
    @State private var arSessionState: ARTrackingState = .initializing

    enum MeasureStep { case tapTop, tapBottom, done }

    var body: some View {
        ZStack {
            ARViewRepresentable(
                onTap: handleARTap,
                onSessionStateChange: { arSessionState = $0 },
                topPoint: topPoint,
                bottomPoint: bottomPoint
            )
            .ignoresSafeArea()

            VStack {
                if arSessionState == .initializing {
                    Label("Scanning surfaces…", systemImage: "viewfinder")
                        .font(.caption).bold()
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.top, 8)
                }

                Spacer()

                VStack(spacing: 12) {
                    switch currentStep {
                    case .tapTop:
                        Text("Tap the top rim of your bottle")
                            .font(.headline).bold()
                        Text("Point at the bottle mouth and tap where the rim is.")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    case .tapBottom:
                        Text("Tap the bottom of your bottle")
                            .font(.headline).bold()
                        Text("Pan down and tap the base to measure height.")
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
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func handleARTap(worldPosition: SIMD3<Float>) {
        switch currentStep {
        case .tapTop:
            topPoint = worldPosition
            withAnimation { currentStep = .tapBottom }
        case .tapBottom:
            bottomPoint = worldPosition
            if let top = topPoint {
                let diff = worldPosition - top
                let distanceMeters = sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)
                measuredHeightCM = Double(distanceMeters) * 100.0
            }
            withAnimation { currentStep = .done }
        case .done:
            break
        }
    }
}
