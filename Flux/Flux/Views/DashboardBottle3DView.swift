import SwiftUI
import SceneKit

struct DashboardBottle3DView: View {
    let fillFraction: Float
    var customProfile: [CGPoint]? = nil
    var multiAngleProfiles: [[CGPoint]]? = nil
    var bottleColor: UIColor? = nil

    var body: some View {
        SceneView(
            scene: makeScene(),
            options: [.allowsCameraControl, .autoenablesDefaultLighting]
        )
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        let glassMat = SCNMaterial()
        let scannedColor = bottleColor ?? UIColor(red: 0.35, green: 0.65, blue: 0.95, alpha: 1)
        // Keep an opaque-enough tint so the scanned mesh remains visible on Dashboard.
        glassMat.diffuse.contents = scannedColor.withAlphaComponent(0.92)
        glassMat.emission.contents = scannedColor.withAlphaComponent(0.16)
        glassMat.specular.contents = UIColor.white
        glassMat.shininess = 80
        glassMat.transparency = 0.82
        glassMat.cullMode = .back

        let waterMat = SCNMaterial()
        let color: UIColor
        switch fillFraction {
        case 0..<0.25: color = UIColor(red: 0.95, green: 0.25, blue: 0.1, alpha: 0.85)
        case 0.25..<0.5: color = UIColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 0.85)
        case 0.5..<0.75: color = UIColor(red: 0.15, green: 0.5, blue: 1.0, alpha: 0.85)
        default: color = UIColor(red: 0.1, green: 0.8, blue: 0.35, alpha: 0.85)
        }
        waterMat.diffuse.contents = color
        waterMat.transparency = 0.45

        let safeFill = max(0.01, min(CGFloat(fillFraction), 1.0))

        if let profiles = multiAngleProfiles, profiles.count >= 3 {
            let glassGeo = BottleMeshGenerator.generateMultiAngleMesh(from: profiles, isWaterFill: false)
            glassGeo.materials = [glassMat]
            scene.rootNode.addChildNode(SCNNode(geometry: glassGeo))

            let waterProfiles = BottleMeshGenerator.sliceMultiAngleProfiles(profiles, fillFraction: safeFill)
            let waterGeo = BottleMeshGenerator.generateMultiAngleMesh(from: waterProfiles, isWaterFill: true)
            waterGeo.materials = [waterMat]
            scene.rootNode.addChildNode(SCNNode(geometry: waterGeo))
        } else if let profile = customProfile, !profile.isEmpty {
            let glassGeo = BottleMeshGenerator.generateRevolvedMesh(from: profile, isWaterFill: false)
            glassGeo.materials = [glassMat]
            scene.rootNode.addChildNode(SCNNode(geometry: glassGeo))

            // Backward-compatible model for profiles created before multi-angle scanning.
            let waterProfile = BottleMeshGenerator.sliceProfile(profile, fillFraction: safeFill)
            let waterGeo = BottleMeshGenerator.generateRevolvedMesh(from: waterProfile, isWaterFill: true)
            waterGeo.materials = [waterMat]
            scene.rootNode.addChildNode(SCNNode(geometry: waterGeo))
        } else {
            let bottleHeight: CGFloat = 0.6
            let bottleRadius: CGFloat = 0.15

            let bodyGeo = SCNCylinder(radius: bottleRadius, height: bottleHeight)
            bodyGeo.materials = [glassMat]
            let bodyNode = SCNNode(geometry: bodyGeo)
            bodyNode.position = SCNVector3(0, bottleHeight / 2, 0)

            let capGeo = SCNCylinder(radius: bottleRadius, height: 0.05)
            let capMat = SCNMaterial()
            capMat.diffuse.contents = UIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
            capGeo.materials = [capMat]
            let capNode = SCNNode(geometry: capGeo)
            capNode.position = SCNVector3(0, bottleHeight + 0.025, 0)

            let waterHeight = bottleHeight * safeFill
            let waterGeo = SCNCylinder(radius: bottleRadius * 0.95, height: waterHeight)
            waterGeo.materials = [waterMat]
            let waterNode = SCNNode(geometry: waterGeo)
            waterNode.position = SCNVector3(0, waterHeight / 2, 0)

            scene.rootNode.addChildNode(bodyNode)
            scene.rootNode.addChildNode(capNode)
            scene.rootNode.addChildNode(waterNode)
        }

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0.32, 1.3)
        cameraNode.look(at: SCNVector3(0, 0.3, 0))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }
}
