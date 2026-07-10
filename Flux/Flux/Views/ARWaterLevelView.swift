import SwiftUI
import RealityKit
import ARKit
import SwiftData

// MARK: - Main View
struct ARWaterLevelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [UserSettings]

    @State private var isPlaced = false

    private var currentSettings: UserSettings {
        if let first = settingsList.first { return first }
        let new = UserSettings()
        modelContext.insert(new)
        return new
    }

    /// Fill fraction: remaining / capacity from last scan (0.0 to 1.0)
    private var fillFraction: Float {
        currentSettings.bottleFillFraction
    }

    private var remainingML: Double { currentSettings.lastScanRemainingML }
    private var capacityML: Double { currentSettings.lastScanBottleCapacityML }

    private var fillColor: Color {
        switch fillFraction {
        case 0..<0.25: return .red
        case 0.25..<0.5: return .orange
        case 0.5..<0.75: return .blue
        default: return Color(red: 0.1, green: 0.7, blue: 0.3)
        }
    }

    var body: some View {
        ZStack {
            // AR Scene
            ARWaterBottleRepresentable(fillFraction: fillFraction, isPlaced: $isPlaced)
                .ignoresSafeArea()

            VStack {
                // Top bar
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white, Color.black.opacity(0.5))
                    }
                    Spacer()
                    Text("AR Bottle")
                        .font(.headline).bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                    Spacer()
                    // Placeholder to balance layout
                    Spacer().frame(width: 32)
                }
                .padding()

                Spacer()

                // Bottle info card
                VStack(spacing: 12) {
                    // Remaining amount
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(remainingML > 0 ? "\(Int(remainingML))" : "--")
                            .font(.system(size: 48, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        Text("ml left")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                            .offset(y: -8)
                        Spacer()
                        Text("\(Int(capacityML)) ml bottle")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                    }

                    // Fill bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.2))
                            RoundedRectangle(cornerRadius: 6)
                                .fill(fillColor)
                                .frame(width: geo.size.width * CGFloat(fillFraction))
                                .animation(.spring(duration: 0.8), value: fillFraction)
                        }
                        .frame(height: 10)
                    }
                    .frame(height: 10)

                    if remainingML <= 0 {
                        Label("Scan your bottle first to sync water level", systemImage: "camera.viewfinder")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(20)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
                .padding(.horizontal)

                // Tap instruction
                if !isPlaced {
                    Label("Tap a flat surface to place your bottle", systemImage: "hand.tap")
                        .font(.caption).bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                }
                Spacer().frame(height: 30)
            }
        }
    }
}

// MARK: - ARKit / RealityKit Representable
struct ARWaterBottleRepresentable: UIViewRepresentable {
    let fillFraction: Float
    @Binding var isPlaced: Bool

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.renderOptions = [.disableDepthOfField]

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        arView.session.run(config)
        arView.debugOptions = [.showFeaturePoints]

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)

        context.coordinator.arView = arView
        context.coordinator.fillFraction = fillFraction
        context.coordinator.onPlaced = { isPlaced = true }
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateWaterLevel(to: fillFraction)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Coordinator
    final class Coordinator: NSObject {
        weak var arView: ARView?
        var fillFraction: Float = 0
        var onPlaced: (() -> Void)?
        var bottleAnchor: AnchorEntity?
        var waterEntity: ModelEntity?

        // Bottle physical dimensions (in metres)
        let bottleH: Float = 0.22
        let bottleR: Float = 0.038
        let neckH:   Float = 0.04
        let neckR:   Float = 0.022

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView, bottleAnchor == nil else { return }
            let pt = gesture.location(in: arView)
            guard let result = arView.raycast(
                from: pt, allowing: .estimatedPlane, alignment: .horizontal
            ).first else { return }
            buildBottle(at: result.worldTransform, in: arView)
            arView.debugOptions = []
            onPlaced?()
        }

        func buildBottle(at worldTransform: simd_float4x4, in arView: ARView) {
            let anchor = AnchorEntity(world: worldTransform)

            // Glass body — semi-transparent
            let bodyMesh = MeshResource.generateCylinder(height: bottleH, radius: bottleR)
            var glassMat = PhysicallyBasedMaterial()
            glassMat.baseColor = .init(tint: UIColor(red: 0.85, green: 0.93, blue: 1.0, alpha: 0.2))
            glassMat.roughness = .init(floatLiteral: 0.05)
            glassMat.metallic  = .init(floatLiteral: 0.2)
            glassMat.blending  = .transparent(opacity: .init(floatLiteral: 0.28))
            let body = ModelEntity(mesh: bodyMesh, materials: [glassMat])
            body.position = [0, bottleH / 2, 0]

            // Neck
            let neckMesh = MeshResource.generateCylinder(height: neckH, radius: neckR)
            let neck = ModelEntity(mesh: neckMesh, materials: [glassMat])
            neck.position = [0, bottleH + neckH / 2, 0]

            // Bottom cap
            let capMesh = MeshResource.generateBox(
                size: [bottleR * 2, 0.006, bottleR * 2], cornerRadius: 0.003)
            var capMat = PhysicallyBasedMaterial()
            capMat.baseColor = .init(tint: UIColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1.0))
            capMat.roughness = .init(floatLiteral: 0.4)
            let cap = ModelEntity(mesh: capMesh, materials: [capMat])
            cap.position = [0, 0.003, 0]

            // Lid
            let lidMesh = MeshResource.generateCylinder(height: 0.015, radius: neckR + 0.003)
            var lidMat = PhysicallyBasedMaterial()
            lidMat.baseColor = .init(tint: UIColor(red: 0.05, green: 0.3, blue: 0.85, alpha: 1.0))
            lidMat.roughness = .init(floatLiteral: 0.3)
            let lid = ModelEntity(mesh: lidMesh, materials: [lidMat])
            lid.position = [0, bottleH + neckH + 0.0075, 0]

            // Water fill (scale Y axis to represent remaining fraction)
            let waterMesh = MeshResource.generateCylinder(height: bottleH, radius: bottleR * 0.88)
            let waterMat = makeWaterMaterial(for: fillFraction)
            let water = ModelEntity(mesh: waterMesh, materials: [waterMat])
            let initialFill = max(0.005, fillFraction)
            water.scale    = [1, initialFill, 1]
            water.position = [0, (bottleH * initialFill) / 2, 0]
            self.waterEntity = water

            anchor.addChild(cap)
            anchor.addChild(water)
            anchor.addChild(body)
            anchor.addChild(neck)
            anchor.addChild(lid)
            arView.scene.addAnchor(anchor)
            self.bottleAnchor = anchor

            // Pop-in entrance animation
            anchor.scale = [0.01, 0.01, 0.01]
            var t = anchor.transform
            t.scale = [1, 1, 1]
            anchor.move(to: t, relativeTo: nil, duration: 0.5, timingFunction: .easeOut)
        }

        func updateWaterLevel(to fraction: Float) {
            guard let water = waterEntity else { return }
            let fill = max(0.005, min(fraction, 1.0))

            water.model?.materials = [makeWaterMaterial(for: fill)]

            var newTransform = water.transform
            newTransform.scale       = [1, fill, 1]
            newTransform.translation = [0, (bottleH * fill) / 2, 0]
            water.move(to: newTransform, relativeTo: water.parent,
                       duration: 0.9, timingFunction: .easeInOut)
        }

        private func makeWaterMaterial(for fraction: Float) -> PhysicallyBasedMaterial {
            var mat = PhysicallyBasedMaterial()
            let color: UIColor
            switch fraction {
            case 0..<0.25: color = UIColor(red: 0.95, green: 0.25, blue: 0.1,  alpha: 0.8)
            case 0.25..<0.5: color = UIColor(red: 1.0,  green: 0.55, blue: 0.0,  alpha: 0.8)
            case 0.5..<0.75: color = UIColor(red: 0.15, green: 0.5,  blue: 1.0,  alpha: 0.82)
            default:         color = UIColor(red: 0.1,  green: 0.8,  blue: 0.35, alpha: 0.82)
            }
            mat.baseColor = .init(tint: color)
            mat.roughness = .init(floatLiteral: 0.1)
            mat.metallic  = .init(floatLiteral: 0.0)
            mat.blending  = .transparent(opacity: .init(floatLiteral: 0.82))
            return mat
        }
    }
}
