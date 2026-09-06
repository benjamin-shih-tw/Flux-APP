import SwiftUI
import RealityKit
import ARKit

enum ARTrackingState { case initializing, ready, limited }

/// Shared ARKit view for bottle height measurement (tap top + bottom).
struct ARViewRepresentable: UIViewRepresentable {
    var onTap: (SIMD3<Float>) -> Void
    var onTapFailure: ((String) -> Void)? = nil
    var onSessionStateChange: (ARTrackingState) -> Void
    var topPoint: SIMD3<Float>?
    var bottomPoint: SIMD3<Float>?
    var verticalMeasurementBase: SIMD3<Float>? = nil
    var horizontalPlaneOnly: Bool = false

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.worldAlignment = .gravity
        config.isAutoFocusEnabled = true
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        context.coordinator.arView = arView
        context.coordinator.onTap = onTap
        context.coordinator.onTapFailure = onTapFailure
        context.coordinator.onSessionStateChange = onSessionStateChange
        context.coordinator.verticalMeasurementBase = verticalMeasurementBase
        context.coordinator.horizontalPlaneOnly = horizontalPlaneOnly
        arView.session.delegate = context.coordinator
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        if horizontalPlaneOnly {
            let coaching = ARCoachingOverlayView()
            coaching.session = arView.session
            coaching.goal = .horizontalPlane
            coaching.activatesAutomatically = true
            coaching.translatesAutoresizingMaskIntoConstraints = false
            arView.addSubview(coaching)
            NSLayoutConstraint.activate([
                coaching.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
                coaching.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
                coaching.topAnchor.constraint(equalTo: arView.topAnchor),
                coaching.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
            ])
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onTapFailure = onTapFailure
        context.coordinator.onSessionStateChange = onSessionStateChange
        context.coordinator.verticalMeasurementBase = verticalMeasurementBase
        context.coordinator.horizontalPlaneOnly = horizontalPlaneOnly
        context.coordinator.updatePoints(top: topPoint, bottom: bottomPoint, in: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        var onTap: ((SIMD3<Float>) -> Void)?
        var onTapFailure: ((String) -> Void)?
        var onSessionStateChange: ((ARTrackingState) -> Void)?
        var topAnchor: AnchorEntity?
        var bottomAnchor: AnchorEntity?
        var verticalMeasurementBase: SIMD3<Float>?
        var horizontalPlaneOnly = false
        var trackingIsReady = false

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView else { return }
            guard trackingIsReady else {
                onTapFailure?("Move the phone slowly until tracking is ready, then tap again.")
                return
            }
            let location = gesture.location(in: arView)
            if let base = verticalMeasurementBase {
                guard let ray = arView.ray(through: location),
                      let position = BottleARHeightSolver.pointOnVerticalThroughBase(
                   rayOrigin: ray.origin,
                   rayDirection: ray.direction,
                   base: base
                      ) else {
                    onTapFailure?("Could not locate the bottle top. Keep the full bottle visible and tap its centre.")
                    return
                }
                onTap?(position)
                return
            }

            let alignment: ARRaycastQuery.TargetAlignment = horizontalPlaneOnly ? .horizontal : .any
            let targets: [ARRaycastQuery.Target] = [
                .existingPlaneGeometry,
                .existingPlaneInfinite,
                .estimatedPlane
            ]
            if let result = targets.lazy.compactMap({ target in
                arView.raycast(from: location, allowing: target, alignment: alignment).first
            }).first {
                let position = SIMD3<Float>(
                    result.worldTransform.columns.3.x,
                    result.worldTransform.columns.3.y,
                    result.worldTransform.columns.3.z
                )
                onTap?(position)
            } else {
                onTapFailure?("No table or floor was detected there. Move the phone slowly around the bottle, then tap the base again.")
            }
        }

        func updatePoints(top: SIMD3<Float>?, bottom: SIMD3<Float>?, in arView: ARView) {
            if top == nil, let topAnchor {
                arView.scene.removeAnchor(topAnchor)
                self.topAnchor = nil
            }
            if bottom == nil, let bottomAnchor {
                arView.scene.removeAnchor(bottomAnchor)
                self.bottomAnchor = nil
            }
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
            case .normal:
                trackingIsReady = true
                onSessionStateChange?(.ready)
            case .limited, .notAvailable:
                trackingIsReady = false
                onSessionStateChange?(.limited)
            }
        }
    }
}

enum BottleARHeightSolver {
    static func pointOnVerticalThroughBase(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        base: SIMD3<Float>
    ) -> SIMD3<Float>? {
        let horizontalDirection = SIMD2<Float>(rayDirection.x, rayDirection.z)
        let denominator = simd_length_squared(horizontalDirection)
        guard denominator > 0.000001 else { return nil }

        let horizontalOffset = SIMD2<Float>(base.x - rayOrigin.x, base.z - rayOrigin.z)
        let distanceAlongRay = simd_dot(horizontalOffset, horizontalDirection) / denominator
        guard distanceAlongRay > 0 else { return nil }

        let pointOnRay = rayOrigin + rayDirection * distanceAlongRay
        return SIMD3<Float>(base.x, pointOnRay.y, base.z)
    }
}
