import SwiftUI
import RealityKit
import ARKit

enum ARTrackingState { case initializing, ready, limited }

/// Shared ARKit view for bottle height measurement (tap top + bottom).
struct ARViewRepresentable: UIViewRepresentable {
    var onTap: (SIMD3<Float>) -> Void
    var onSessionStateChange: (ARTrackingState) -> Void
    var topPoint: SIMD3<Float>?
    var bottomPoint: SIMD3<Float>?

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        arView.session.run(config)
        arView.session.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)

        context.coordinator.arView = arView
        context.coordinator.onTap = onTap
        context.coordinator.onSessionStateChange = onSessionStateChange
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updatePoints(top: topPoint, bottom: bottomPoint, in: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        var onTap: ((SIMD3<Float>) -> Void)?
        var onSessionStateChange: ((ARTrackingState) -> Void)?
        var topAnchor: AnchorEntity?
        var bottomAnchor: AnchorEntity?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView else { return }
            let location = gesture.location(in: arView)
            if let result = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first {
                let position = SIMD3<Float>(
                    result.worldTransform.columns.3.x,
                    result.worldTransform.columns.3.y,
                    result.worldTransform.columns.3.z
                )
                onTap?(position)
            }
        }

        func updatePoints(top: SIMD3<Float>?, bottom: SIMD3<Float>?, in arView: ARView) {
            if let topPos = top, topAnchor == nil {
                let anchor = AnchorEntity(world: topPos)
                let sphere = ModelEntity(
                    mesh: .generateSphere(radius: 0.015),
                    materials: [SimpleMaterial(color: .blue, isMetallic: false)]
                )
                anchor.addChild(sphere)
                arView.scene.addAnchor(anchor)
                topAnchor = anchor
            }
            if let bottomPos = bottom, bottomAnchor == nil {
                let anchor = AnchorEntity(world: bottomPos)
                let sphere = ModelEntity(
                    mesh: .generateSphere(radius: 0.015),
                    materials: [SimpleMaterial(color: .orange, isMetallic: false)]
                )
                anchor.addChild(sphere)
                arView.scene.addAnchor(anchor)
                bottomAnchor = anchor
            }
        }

        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            switch camera.trackingState {
            case .normal: onSessionStateChange?(.ready)
            case .limited, .notAvailable: onSessionStateChange?(.limited)
            }
        }
    }
}
