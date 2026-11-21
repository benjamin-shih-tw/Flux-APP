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
            options: [.allowsCameraControl]
        )
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.13, green: 0.145, blue: 0.165, alpha: 1)

        let glassMat = SCNMaterial()
        glassMat.diffuse.contents = glassTexture()
        glassMat.emission.contents = UIColor(red: 0.12, green: 0.2, blue: 0.26, alpha: 1)
        glassMat.specular.contents = UIColor.white
        glassMat.shininess = 95
        glassMat.transparency = 0.4
        glassMat.fresnelExponent = 2
        glassMat.cullMode = .back

        let waterMat = SCNMaterial()
        waterMat.diffuse.contents = UIColor(red: 0.22, green: 0.65, blue: 0.94, alpha: 1)
        waterMat.emission.contents = UIColor(red: 0.08, green: 0.32, blue: 0.55, alpha: 1)
        waterMat.specular.contents = UIColor(red: 0.8, green: 0.95, blue: 1, alpha: 1)
        waterMat.shininess = 80
        waterMat.transparency = 0.86

        let safeFill = max(0, min(CGFloat(fillFraction), 1.0))

        if let profiles = multiAngleProfiles, profiles.count >= 3 {
            let glassGeo = BottleMeshGenerator.generateMultiAngleMesh(from: profiles, isWaterFill: false)
            glassGeo.materials = [glassMat]
            scene.rootNode.addChildNode(SCNNode(geometry: glassGeo))

            if safeFill > 0.01 {
                let waterProfiles = BottleMeshGenerator.sliceMultiAngleProfiles(profiles, fillFraction: safeFill)
                let waterGeo = BottleMeshGenerator.generateMultiAngleMesh(from: waterProfiles, isWaterFill: true)
                waterGeo.materials = [waterMat]
                scene.rootNode.addChildNode(SCNNode(geometry: waterGeo))
            }
        } else if let profile = customProfile, !profile.isEmpty {
            let glassGeo = BottleMeshGenerator.generateRevolvedMesh(from: profile, isWaterFill: false)
            glassGeo.materials = [glassMat]
            scene.rootNode.addChildNode(SCNNode(geometry: glassGeo))

            // Backward-compatible model for profiles created before multi-angle scanning.
            if safeFill > 0.01 {
                let waterProfile = BottleMeshGenerator.sliceProfile(profile, fillFraction: safeFill)
                let waterGeo = BottleMeshGenerator.generateRevolvedMesh(from: waterProfile, isWaterFill: true)
                waterGeo.materials = [waterMat]
                scene.rootNode.addChildNode(SCNNode(geometry: waterGeo))
            }
        } else {
            let profile = [
                CGPoint(x: 0.13, y: 0), CGPoint(x: 0.145, y: 0.02),
                CGPoint(x: 0.145, y: 0.43), CGPoint(x: 0.13, y: 0.48),
                CGPoint(x: 0.10, y: 0.52), CGPoint(x: 0.10, y: 0.60)
            ]
            let body = BottleMeshGenerator.generateRevolvedMesh(from: profile)
            body.materials = [glassMat]
            scene.rootNode.addChildNode(SCNNode(geometry: body))

            if safeFill > 0.01 {
                let waterProfile = BottleMeshGenerator.sliceProfile(profile, fillFraction: safeFill)
                let water = BottleMeshGenerator.generateRevolvedMesh(from: waterProfile, isWaterFill: true)
                water.materials = [waterMat]
                scene.rootNode.addChildNode(SCNNode(geometry: water))

                let surface = SCNCylinder(radius: max(0.02, waterProfile.last?.x ?? 0.139), height: 0.003)
                let surfaceMaterial = SCNMaterial()
                surfaceMaterial.diffuse.contents = UIColor(red: 0.48, green: 0.85, blue: 1, alpha: 1)
                surfaceMaterial.emission.contents = UIColor(red: 0.18, green: 0.48, blue: 0.67, alpha: 1)
                surfaceMaterial.transparency = 0.8
                surface.materials = [surfaceMaterial]
                let surfaceNode = SCNNode(geometry: surface)
                surfaceNode.position = SCNVector3(0, Float(waterProfile.map(\.y).max() ?? 0), 0)
                scene.rootNode.addChildNode(surfaceNode)
            }

            let handleMaterial = SCNMaterial()
            handleMaterial.diffuse.contents = UIColor(red: 0.26, green: 0.3, blue: 0.33, alpha: 1)
            handleMaterial.specular.contents = UIColor.white
            handleMaterial.metalness.contents = 0.65
            let handle = SCNTorus(ringRadius: 0.055, pipeRadius: 0.005)
            handle.materials = [handleMaterial]
            let handleNode = SCNNode(geometry: handle)
            handleNode.eulerAngles.x = .pi / 2
            handleNode.position = SCNVector3(0.12, 0.52, -0.06)
            scene.rootNode.addChildNode(handleNode)

            let highlightMaterial = SCNMaterial()
            highlightMaterial.diffuse.contents = UIColor.white
            highlightMaterial.lightingModel = .constant
            highlightMaterial.transparency = 0.32
            let highlight = SCNPlane(width: 0.012, height: 0.37)
            highlight.materials = [highlightMaterial]
            let highlightNode = SCNNode(geometry: highlight)
            highlightNode.position = SCNVector3(-0.105, 0.23, 0.105)
            scene.rootNode.addChildNode(highlightNode)

            let edgeMaterial = SCNMaterial()
            edgeMaterial.diffuse.contents = UIColor(red: 0.62, green: 0.82, blue: 0.93, alpha: 1)
            edgeMaterial.emission.contents = UIColor(red: 0.1, green: 0.2, blue: 0.26, alpha: 1)
            edgeMaterial.transparency = 0.65
            for (height, radius) in [(0.012, 0.143), (0.48, 0.13)] {
                let edge = SCNTorus(ringRadius: radius, pipeRadius: 0.004)
                edge.materials = [edgeMaterial]
                let edgeNode = SCNNode(geometry: edge)
                edgeNode.position = SCNVector3(0, height, 0)
                scene.rootNode.addChildNode(edgeNode)
            }
        }

        let topY = customProfile?.map(\.y).max() ?? 0.6
        let topRadius = customProfile?.sorted(by: { $0.y < $1.y }).last?.x ?? 0.10
        let capMaterial = SCNMaterial()
        capMaterial.diffuse.contents = UIColor(red: 0.72, green: 0.76, blue: 0.78, alpha: 1)
        capMaterial.emission.contents = UIColor(white: 0.16, alpha: 1)
        capMaterial.specular.contents = UIColor.white
        capMaterial.shininess = 100
        capMaterial.metalness.contents = 0.35
        let cap = SCNCylinder(radius: max(0.04, min(topRadius, 0.18)), height: 0.055)
        cap.materials = [capMaterial]
        let capNode = SCNNode(geometry: cap)
        capNode.position = SCNVector3(0, Float(topY) + 0.028, 0)
        scene.rootNode.addChildNode(capNode)

        let rim = SCNTorus(ringRadius: max(0.04, min(topRadius, 0.18)), pipeRadius: 0.006)
        rim.materials = [capMaterial]
        let rimNode = SCNNode(geometry: rim)
        rimNode.position = SCNVector3(0, Float(topY) + 0.057, 0)
        scene.rootNode.addChildNode(rimNode)

        for offset in [0.004, 0.04] {
            let band = SCNTorus(ringRadius: max(0.04, min(topRadius, 0.18)), pipeRadius: 0.004)
            band.materials = [capMaterial]
            let bandNode = SCNNode(geometry: band)
            bandNode.position = SCNVector3(0, Float(topY) + Float(offset), 0)
            scene.rootNode.addChildNode(bandNode)
        }

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 350
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .omni
        key.intensity = 1100
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-0.8, 1.2, 1.2)
        scene.rootNode.addChildNode(keyNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.usesOrthographicProjection = true
        cameraNode.camera?.orthographicScale = 0.43
        cameraNode.position = SCNVector3(0, 0.35, 1.4)
        cameraNode.look(at: SCNVector3(0, 0.32, 0))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }

    private func glassTexture() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 8))
        return renderer.image { context in
            let colors = [
                UIColor(red: 0.2, green: 0.31, blue: 0.38, alpha: 1),
                UIColor(red: 0.72, green: 0.86, blue: 0.93, alpha: 1),
                UIColor(red: 0.35, green: 0.51, blue: 0.6, alpha: 1),
                UIColor(red: 0.25, green: 0.37, blue: 0.45, alpha: 1),
                UIColor(red: 0.7, green: 0.84, blue: 0.91, alpha: 1),
                UIColor(red: 0.2, green: 0.31, blue: 0.38, alpha: 1)
            ].map(\.cgColor) as CFArray
            let locations: [CGFloat] = [0, 0.12, 0.3, 0.63, 0.87, 1]
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: locations
            ) else { return }
            context.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: 256, y: 0),
                options: []
            )
        }
    }
}
