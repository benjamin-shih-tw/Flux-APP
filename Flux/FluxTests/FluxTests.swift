//
//  FluxTests.swift
//  FluxTests
//
//  Created by Benjamin on 2026/7/9.
//

import Testing
import CoreGraphics
import CoreVideo
import Foundation
import simd
@testable import Flux

struct FluxTests {
    @Test @MainActor func damagedProfilesNeverSilentlyBecomeCylinders() {
        let api = WaterAPIManager()
        let invalid: [([Double], [Double])] = [
            ([0, 20], []), ([0], [3]), ([0, 20], [3, .nan]),
            ([1, 20], [3, 3]), ([0, 10, 10, 20], [3, 3, 3, 3]),
            ([0, 10], [3, 3]), ([0, 20], [3, -1]),
            ([0, .infinity], [3, 3])
        ]
        for (heights, radii) in invalid {
            let bottle = BottleProfile(totalVolumeMl: 500, heightCM: 20, diameterCM: 6)
            bottle.profileHeightCM = heights
            bottle.profileRadiusCM = radii
            #expect(throws: WaterAPIManager.APIError.self) {
                try api.buildProfileJSON(bottle: bottle)
            }
        }
    }

    @Test @MainActor func validProfileIsTransmittedWithoutShapeSubstitution() throws {
        let api = WaterAPIManager()
        let bottle = BottleProfile(totalVolumeMl: 500, heightCM: 20, diameterCM: 6)
        #expect(try api.buildProfileJSON(bottle: bottle) == "{}")
        bottle.profileHeightCM = [0, 10, 20]
        bottle.profileRadiusCM = [3, 4, 3]
        let json = try api.buildProfileJSON(bottle: bottle)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [Double]])
        #expect(decoded["heights_cm"] == [0, 10, 20])
        #expect(decoded["radii_cm"] == [3, 4, 3])
    }

    @Test func calibratedCaptureRejectsInvalidOrNonSquareIntrinsics() {
        #expect(WaterCaptureGeometry.focalLength(fx: 1200, fy: 1200) == 1200)
        #expect(WaterCaptureGeometry.focalLength(fx: .nan, fy: 1200) == nil)
        #expect(WaterCaptureGeometry.focalLength(fx: 0, fy: 1200) == nil)
        #expect(WaterCaptureGeometry.focalLength(fx: 1200, fy: 1300) == nil)
    }

    @Test func captureAlignmentUsesCameraDirectionAtExposure() {
        #expect(WaterCaptureGeometry.alignmentScore(cameraZWorldY: 1) == 1)
        #expect(WaterCaptureGeometry.alignmentScore(cameraZWorldY: 0) == 0)
        #expect(WaterCaptureGeometry.alignmentScore(cameraZWorldY: -1) == 0)
        #expect(WaterCaptureGeometry.alignmentScore(cameraZWorldY: .nan) == 0)
        #expect(WaterCaptureGeometry.alignmentScore(cameraZWorldY: cos(6 * .pi / 180)) == 0)
    }

    @Test @MainActor func equalCapacityBottlesHaveDifferentMeasurementIdentity() {
        let first = BottleProfile(totalVolumeMl: 500)
        let second = BottleProfile(totalVolumeMl: 500)
        #expect(first.measurementID != second.measurementID)
        #expect(UserSettings().lastScanBottleID == nil)
    }


    @Test func frustumIntegrationMatchesAnalyticVolume() {
        let profile: [(height: Double, radius: Double)] = [(0, 4), (20, 1)]
        let expected = Double.pi * 20 * (16 + 4 + 1) / 3
        #expect(abs(BottleVolumeCalculator.totalVolumeML(profile: profile) - expected) < 1e-8)
        let partial = Double.pi * 10 * (16 + 10 + 6.25) / 3
        #expect(abs(BottleVolumeCalculator.volumeBelowHeight(
            profile: profile, waterHeightCM: 10
        ) - partial) < 1e-8)
    }

    @Test func volumeDoesNotDependOnProfileSamplingDensity() {
        let sparse: [(height: Double, radius: Double)] = [(0, 4), (20, 1)]
        let dense = (0...100).map { index in
            (height: Double(index) / 5, radius: 4 - Double(index) * 0.03)
        }
        #expect(abs(BottleVolumeCalculator.totalVolumeML(profile: sparse)
                    - BottleVolumeCalculator.totalVolumeML(profile: dense)) < 1e-8)
    }

    @Test func capacityFittedProfileMatchesKnownCapacity() {
        let rawProfile = (0...40).map { index in
            CGPoint(x: 0.15, y: 0.05 + CGFloat(index) / 40.0 * 0.90)
        }

        let result = BottleVolumeCalculator.fitProfileToCapacity(
            rawPoints: rawProfile,
            capacityML: 500
        )

        #expect(result != nil)
        #expect(abs((result?.computedVolumeML ?? 0) - 500) < 0.01)
        #expect((result?.physical.count ?? 0) == rawProfile.count)
        #expect((result?.qualityScore ?? 0) > 0.9)
    }

    @Test func capacityFitPreservesShapeAndUsesCubicScaling() {
        let rawProfile = (0...40).map { index in
            let height = CGFloat(index) / 40.0
            return CGPoint(x: 0.12 + height * 0.04, y: height)
        }

        let small = BottleVolumeCalculator.fitProfileToCapacity(rawPoints: rawProfile, capacityML: 500)
        let large = BottleVolumeCalculator.fitProfileToCapacity(rawPoints: rawProfile, capacityML: 1000)

        #expect(small != nil)
        #expect(large != nil)
        let expectedScale = pow(2.0, 1.0 / 3.0)
        #expect(abs((large?.heightCM ?? 0) / (small?.heightCM ?? 1) - expectedScale) < 0.0001)
    }

    @Test func capacityFitRejectsInvalidInputs() {
        let tooFewPoints = [CGPoint(x: 0.1, y: 0), CGPoint(x: 0.1, y: 1)]
        let validProfile = (0...40).map { index in
            CGPoint(x: 0.15, y: 0.05 + CGFloat(index) / 45.0)
        }

        #expect(BottleVolumeCalculator.fitProfileToCapacity(rawPoints: tooFewPoints, capacityML: 500) == nil)
        #expect(BottleVolumeCalculator.fitProfileToCapacity(rawPoints: [], capacityML: 500) == nil)
        #expect(BottleVolumeCalculator.fitProfileToCapacity(rawPoints: validProfile, capacityML: 0) == nil)
    }

    @Test func floatMaskUsesWholePixelsAndKeepsImageCoordinates() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            80,
            120,
            kCVPixelFormatType_OneComponent32Float,
            nil,
            &buffer
        )
        #expect(status == kCVReturnSuccess)
        let mask = try #require(buffer)

        CVPixelBufferLockBaseAddress(mask, [])
        let base = try #require(CVPixelBufferGetBaseAddress(mask))
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        memset(base, 0, CVPixelBufferGetDataSize(mask))
        for y in 10...109 {
            let row = base.advanced(by: y * rowBytes)
            for x in 30...49 {
                row.storeBytes(of: Float(1), toByteOffset: x * MemoryLayout<Float>.stride, as: Float.self)
            }
        }
        CVPixelBufferUnlockBaseAddress(mask, [])

        let result = try BottleProfileExtraction.extractSilhouette(from: mask)
        let expectedRadius = CGFloat(19) / 2 / 120
        #expect(abs((result.rawProfile.first?.x ?? 0) - expectedRadius) < 0.0001)
        #expect(abs((result.normalizedOutline.map(\.x).min() ?? 0) - 0.375) < 0.0001)
        #expect(abs((result.normalizedOutline.map(\.x).max() ?? 0) - 0.6125) < 0.0001)
    }

    @Test func measuredHeightControlsDimensionsWithoutCapacityScaling() {
        let rawProfile = (0...40).map { index in
            CGPoint(x: 0.15, y: CGFloat(index) / 40)
        }

        let result = BottleVolumeCalculator.fitProfileToMeasuredHeight(
            rawPoints: rawProfile,
            heightCM: 24
        )

        #expect(result != nil)
        #expect(abs((result?.heightCM ?? 0) - 24) < 0.0001)
        #expect(abs(((result?.physical.map(\.radius).max() ?? 0) * 2) - 7.2) < 0.0001)
    }

    @Test func arHeightSolverProjectsTopOntoBottleVerticalAxis() throws {
        let camera = SIMD3<Float>(0, 1.5, 0)
        let base = SIMD3<Float>(0, 0, 1)
        let expectedTop = SIMD3<Float>(0, 0.24, 1)
        let direction = simd_normalize(expectedTop - camera)

        let result = try #require(BottleARHeightSolver.pointOnVerticalThroughBase(
            rayOrigin: camera,
            rayDirection: direction,
            base: base
        ))

        #expect(abs(result.y - expectedTop.y) < 0.0001)
        #expect(result.x == base.x)
        #expect(result.z == base.z)
    }

    @Test func displayNormalizationPreservesBottleAspectRatio() throws {
        let physical = [
            CGPoint(x: 4, y: 0),
            CGPoint(x: 4, y: 24)
        ]

        let display = BottleMeshGenerator.normalizeProfileForDisplay(physical, targetHeight: 0.6)
        let height = try #require(display.map(\.y).max()) - (display.map(\.y).min() ?? 0)
        let diameter = try #require(display.map(\.x).max()) * 2

        #expect(abs((height / diameter) - 3) < 0.0001)
    }

    @Test func capacityOCRReadsMillilitresAndLitres() {
        #expect(BottleProfileExtraction.capacityML(fromRecognizedText: "Capacity 1500 ml") == 1500)
        #expect(BottleProfileExtraction.capacityML(fromRecognizedText: "1.5 L") == 1500)
        #expect(BottleProfileExtraction.capacityML(fromRecognizedText: "0,75L") == 750)
        #expect(BottleProfileExtraction.capacityML(fromRecognizedText: "Model 2026") == nil)
    }

    @Test func capacityEstimateIncludesUncertaintyAndPrioritizesDetectedLabel() throws {
        let estimate = try #require(BottleVolumeCalculator.estimateCapacity(
            geometricVolumeML: 1164,
            qualityScore: 0.9,
            detectedLabelCapacityML: 1500
        ))

        #expect(estimate.lowerBoundML <= 1000)
        #expect(estimate.upperBoundML >= 1500)
        #expect(estimate.suggestedCapacitiesML.first == 1500)
    }

}
