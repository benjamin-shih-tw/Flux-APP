import SceneKit
import Foundation
import simd

class BottleMeshGenerator {

    static func generateRevolvedMesh(from profile: [CGPoint], radialSegments: Int = 36, isWaterFill: Bool = false) -> SCNGeometry {
        guard profile.count >= 2 else { return SCNCylinder(radius: 0.1, height: 0.1) }

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var texCoords: [CGPoint] = []
        var indices: [Int32] = []

        let sortedProfile = profile.sorted { $0.y < $1.y }

        for s in 0...radialSegments {
            let angle = (Float(s) / Float(radialSegments)) * Float.pi * 2.0
            let cosTheta = cos(angle)
            let sinTheta = sin(angle)

            for (i, point) in sortedProfile.enumerated() {
                let radius = isWaterFill ? Float(point.x) * 0.95 : Float(point.x)
                let height = Float(point.y)

                let x = radius * cosTheta
                let z = radius * sinTheta

                vertices.append(SCNVector3(x, height, z))

                let previous = sortedProfile[max(0, i - 1)]
                let next = sortedProfile[min(sortedProfile.count - 1, i + 1)]
                let dy = Float(next.y - previous.y)
                let dx = Float(next.x - previous.x)
                let tangent = SIMD2<Float>(dx, dy)
                let normal2D = simd_normalize(SIMD2<Float>(tangent.y, -tangent.x))
                let normal3D = simd_normalize(SIMD3<Float>(
                    normal2D.x * cosTheta,
                    normal2D.y,
                    normal2D.x * sinTheta
                ))
                normals.append(SCNVector3(normal3D.x, normal3D.y, normal3D.z))

                let u = Float(s) / Float(radialSegments)
                let v = Float(i) / Float(sortedProfile.count - 1)
                texCoords.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
            }
        }

        let profileCount = sortedProfile.count
        for s in 0..<radialSegments {
            for i in 0..<(profileCount - 1) {
                let currentLine = s * profileCount
                let nextLine = (s + 1) * profileCount

                let v0 = Int32(currentLine + i)
                let v1 = Int32(currentLine + i + 1)
                let v2 = Int32(nextLine + i)
                let v3 = Int32(nextLine + i + 1)

                indices.append(v0)
                indices.append(v2)
                indices.append(v1)

                indices.append(v1)
                indices.append(v2)
                indices.append(v3)
            }
        }

        let bottomCenterIndex = Int32(vertices.count)
        let minY = Float(sortedProfile.first!.y)
        vertices.append(SCNVector3(0, minY, 0))
        normals.append(SCNVector3(0, -1, 0))
        texCoords.append(CGPoint(x: 0.5, y: 0))

        let topCenterIndex = Int32(vertices.count)
        let maxY = Float(sortedProfile.last!.y)
        vertices.append(SCNVector3(0, maxY, 0))
        normals.append(SCNVector3(0, 1, 0))
        texCoords.append(CGPoint(x: 0.5, y: 1))

        for s in 0..<radialSegments {
            let currentLine = s * profileCount
            let nextLine = (s + 1) * profileCount

            indices.append(bottomCenterIndex)
            indices.append(Int32(nextLine))
            indices.append(Int32(currentLine))

            indices.append(topCenterIndex)
            indices.append(Int32(currentLine + profileCount - 1))
            indices.append(Int32(nextLine + profileCount - 1))
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let texCoordSource = SCNGeometrySource(textureCoordinates: texCoords)

        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.stride)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        return SCNGeometry(sources: [vertexSource, normalSource, texCoordSource], elements: [element])
    }

    /// Normalizes cm-calibrated profile into SceneKit display units.
    static func normalizeProfileForDisplay(_ points: [CGPoint], targetHeight: Float = 0.6) -> [CGPoint] {
        guard !points.isEmpty else { return [] }

        let xs = points.map(\.x)
        let ys = points.map(\.y)

        let maxX = xs.max()!
        let minY = ys.min()!
        let maxY = ys.max()!

        let height = maxY - minY
        guard maxX > 0, height > 0 else { return points }

        return points.map { pt in
            let normalizedRadius = (pt.x / maxX) * CGFloat(targetHeight / 3.0)
            let normalizedHeight = ((pt.y - minY) / height) * CGFloat(targetHeight)
            return CGPoint(x: max(0.001, normalizedRadius), y: normalizedHeight)
        }
    }

    /// Slice profile up to fillFraction (0…1) of total height for accurate water mesh.
    static func sliceProfile(_ profile: [CGPoint], fillFraction: CGFloat) -> [CGPoint] {
        guard profile.count >= 2 else { return profile }
        let sorted = profile.sorted { $0.y < $1.y }
        let minY = sorted.first!.y
        let maxY = sorted.last!.y
        let cutoffY = minY + (maxY - minY) * max(0.01, min(fillFraction, 1.0))

        var sliced: [CGPoint] = []
        for i in 0..<sorted.count {
            let pt = sorted[i]
            if pt.y <= cutoffY {
                sliced.append(pt)
            } else if i > 0 {
                let prev = sorted[i - 1]
                if prev.y < cutoffY {
                    let t = (cutoffY - prev.y) / (pt.y - prev.y)
                    let r = prev.x + t * (pt.x - prev.x)
                    sliced.append(CGPoint(x: r, y: cutoffY))
                }
                break
            }
        }
        return sliced.count >= 2 ? sliced : profile
    }

    /// Build display + physical profiles from raw Vision extraction.
    static func buildProfiles(
        rawPoints: [CGPoint],
        heightCM: Double,
        openingRadiusCM: Double,
        targetDisplayHeight: Float = 0.6
    ) -> (display: [CGPoint], physical: [(height: Double, radius: Double)]) {
        let physical = BottleVolumeCalculator.calibrateProfile(
            rawPoints: rawPoints,
            heightCM: heightCM,
            openingRadiusCM: openingRadiusCM
        )
        let cmPoints = physical.map { CGPoint(x: $0.radius, y: $0.height) }
        let display = normalizeProfileForDisplay(cmPoints, targetHeight: targetDisplayHeight)
        return (display, physical)
    }

    /// Removes per-photo distance and crop variation before profiles are fused.
    /// Radius is expressed relative to that photo's detected bottle height, and y is 0...1.
    static func normalizeProfilesForGeometry(_ profiles: [[CGPoint]]) -> [[CGPoint]] {
        profiles.compactMap { profile in
            let sorted = profile.sorted { $0.y < $1.y }
            guard let minY = sorted.first?.y,
                  let maxY = sorted.last?.y else { return nil }
            let height = maxY - minY
            guard height > 0.001 else { return nil }

            return sorted.map { point in
                CGPoint(
                    x: max(0.0001, point.x / height),
                    y: (point.y - minY) / height
                )
            }
        }
    }

    /// Normalize profiles from a multi-angle scan into SceneKit display units using one shared scale.
    static func normalizeMultiAngleProfilesForDisplay(
        _ profiles: [[CGPoint]],
        targetHeight: Float = 0.6
    ) -> [[CGPoint]] {
        let geometryProfiles = normalizeProfilesForGeometry(profiles)
        let allPoints = geometryProfiles.flatMap { $0 }
        guard !allPoints.isEmpty else { return [] }

        let maxRadius = allPoints.map(\.x).max() ?? 1
        guard maxRadius > 0 else { return geometryProfiles }
        let radiusScale = CGFloat(targetHeight / 3.0) / maxRadius

        return geometryProfiles.map { profile in
            profile.map { point in
                CGPoint(
                    x: max(0.001, point.x * radiusScale),
                    y: point.y * CGFloat(targetHeight)
                )
            }
        }
    }

    /// Averages multi-angle silhouettes for the physical volume approximation.
    /// The 3D Dashboard model still uses every individual profile.
    static func averageProfiles(_ profiles: [[CGPoint]], samples: Int = 50) -> [CGPoint] {
        let validProfiles = profiles.filter { $0.count >= 2 }
        let allPoints = validProfiles.flatMap { $0 }
        guard validProfiles.count >= 1,
              let minY = allPoints.map(\.y).min(),
              let maxY = allPoints.map(\.y).max(),
              maxY > minY else { return validProfiles.first ?? [] }

        return (0..<max(2, samples)).map { index in
            let y = minY + (maxY - minY) * CGFloat(index) / CGFloat(max(1, samples - 1))
            let radii = validProfiles.map { interpolatedRadius(at: y, in: $0) }
            let radius = radii.reduce(0, +) / CGFloat(radii.count)
            return CGPoint(x: radius, y: y)
        }
    }

    /// Builds a low-poly mesh from several side silhouettes captured around a bottle.
    /// Each profile becomes one radial slice, so flattened or asymmetric bottles keep their shape.
    static func generateMultiAngleMesh(
        from profiles: [[CGPoint]],
        heightSegments: Int = 48,
        isWaterFill: Bool = false
    ) -> SCNGeometry {
        let validProfiles = profiles.filter { $0.count >= 2 }
        guard validProfiles.count >= 3 else {
            return generateRevolvedMesh(from: validProfiles.first ?? [], isWaterFill: isWaterFill)
        }

        let minY = validProfiles.flatMap { $0 }.map(\.y).min() ?? 0
        let maxY = validProfiles.flatMap { $0 }.map(\.y).max() ?? 0.6
        let height = maxY - minY
        guard height > 0 else {
            return generateRevolvedMesh(from: validProfiles[0], isWaterFill: isWaterFill)
        }

        let sliceCount = validProfiles.count
        let rows = max(2, heightSegments + 1)
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var texCoords: [CGPoint] = []
        var indices: [Int32] = []

        for row in 0..<rows {
            let y = minY + height * CGFloat(row) / CGFloat(rows - 1)
            for slice in 0..<sliceCount {
                let angle = (Float(slice) / Float(sliceCount)) * Float.pi * 2
                let radius = Float(interpolatedRadius(at: y, in: validProfiles[slice])) * (isWaterFill ? 0.95 : 1.0)
                let x = radius * cos(angle)
                let z = radius * sin(angle)
                vertices.append(SCNVector3(x, Float(y), z))
                normals.append(SCNVector3(cos(angle), 0, sin(angle)))
                texCoords.append(CGPoint(x: CGFloat(slice) / CGFloat(sliceCount), y: CGFloat(row) / CGFloat(rows - 1)))
            }
        }

        for row in 0..<(rows - 1) {
            for slice in 0..<sliceCount {
                let nextSlice = (slice + 1) % sliceCount
                let current = row * sliceCount + slice
                let next = row * sliceCount + nextSlice
                let above = (row + 1) * sliceCount + slice
                let aboveNext = (row + 1) * sliceCount + nextSlice
                indices += [Int32(current), Int32(next), Int32(above), Int32(above), Int32(next), Int32(aboveNext)]
            }
        }

        let bottomCenter = Int32(vertices.count)
        vertices.append(SCNVector3(0, Float(minY), 0))
        normals.append(SCNVector3(0, -1, 0))
        texCoords.append(CGPoint(x: 0.5, y: 0))

        let topCenter = Int32(vertices.count)
        vertices.append(SCNVector3(0, Float(maxY), 0))
        normals.append(SCNVector3(0, 1, 0))
        texCoords.append(CGPoint(x: 0.5, y: 1))

        let topRow = (rows - 1) * sliceCount
        for slice in 0..<sliceCount {
            let nextSlice = (slice + 1) % sliceCount
            indices += [bottomCenter, Int32(nextSlice), Int32(slice)]
            indices += [topCenter, Int32(topRow + slice), Int32(topRow + nextSlice)]
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let texCoordSource = SCNGeometrySource(textureCoordinates: texCoords)
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.stride)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        return SCNGeometry(sources: [vertexSource, normalSource, texCoordSource], elements: [element])
    }

    static func sliceMultiAngleProfiles(_ profiles: [[CGPoint]], fillFraction: CGFloat) -> [[CGPoint]] {
        let valid = profiles.filter { $0.count >= 2 }
        let allPoints = valid.flatMap { $0 }
        guard let minY = allPoints.map(\.y).min(),
              let maxY = allPoints.map(\.y).max(),
              maxY > minY else { return profiles }

        // Water has one horizontal world-space level, not one independent level per side photo.
        let cutoffY = minY + (maxY - minY) * max(0.01, min(fillFraction, 1.0))
        return profiles.map { profile in
            sliceProfile(profile, atWorldHeight: cutoffY)
        }
    }

    private static func sliceProfile(_ profile: [CGPoint], atWorldHeight cutoffY: CGFloat) -> [CGPoint] {
        let sorted = profile.sorted { $0.y < $1.y }
        guard sorted.count >= 2 else { return profile }

        var sliced = sorted.filter { $0.y < cutoffY }
        let radius = interpolatedRadius(at: cutoffY, in: sorted)
        sliced.append(CGPoint(x: radius, y: cutoffY))
        return sliced.count >= 2 ? sliced : [
            CGPoint(x: sorted.first!.x, y: sorted.first!.y),
            CGPoint(x: radius, y: cutoffY)
        ]
    }

    private static func interpolatedRadius(at height: CGFloat, in profile: [CGPoint]) -> CGFloat {
        let sorted = profile.sorted { $0.y < $1.y }
        guard let first = sorted.first, let last = sorted.last else { return 0.001 }
        if height <= first.y { return max(0.001, first.x) }
        if height >= last.y { return max(0.001, last.x) }

        for index in 0..<(sorted.count - 1) {
            let lower = sorted[index]
            let upper = sorted[index + 1]
            if lower.y <= height && height <= upper.y {
                let span = upper.y - lower.y
                guard span > 0 else { return max(0.001, lower.x) }
                let t = (height - lower.y) / span
                return max(0.001, lower.x + t * (upper.x - lower.x))
            }
        }
        return max(0.001, last.x)
    }
}
