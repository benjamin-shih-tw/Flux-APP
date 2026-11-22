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
    @Test @MainActor func guideRequiresAnEdgeAtTheDisplayedRadius() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 256, 256,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        #expect(status == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let plane = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        for y in 0..<256 {
            for x in 0..<256 {
                plane[y * stride + x] = hypot(Double(x-128), Double(y-128)) < 75 ? 50 : 180
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(CalibratedWaterCameraView.alignedRim(pixels, x: 128, y: 128, radius: 75) != nil)
        #expect(CalibratedWaterCameraView.alignedRim(pixels, x: 128, y: 128, radius: 55) == nil)
        let offsetRim = try #require(CalibratedWaterCameraView.alignedRim(pixels, x: 131, y: 130, radius: 77))
        #expect(hypot(offsetRim[0]-128, offsetRim[1]-128) < 3.6)
        #expect(CalibratedWaterCameraView.alignedRim(pixels, x: 148, y: 128, radius: 75) == nil)
    }

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

    @Test func interiorLensPositionsAlwaysStepFartherThanRim() {
        let fullSweep = WaterCaptureGeometry.fullInteriorLensSweep()
        #expect(fullSweep.count == 6)
        #expect(fullSweep.first! >= 0.15 && fullSweep.last! >= 0.80)
        #expect(zip(fullSweep, fullSweep.dropFirst()).allSatisfy { $0 < $1 })

        let nearSweep = WaterCaptureGeometry.interiorLensPositions(rimLensPosition: 0.08, steps: 5)
        #expect(nearSweep.count == 5)
        #expect(nearSweep.first! > 0.18)
        #expect(nearSweep.last! >= 0.80)
        #expect(zip(nearSweep, nearSweep.dropFirst()).allSatisfy { $0 < $1 })

        let midSweep = WaterCaptureGeometry.interiorLensPositions(rimLensPosition: 0.45, steps: 5)
        #expect(midSweep.first! >= 0.54)
        #expect(midSweep.last! <= 0.90)
        #expect(zip(midSweep, midSweep.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func reprojectRimHandlesFocusBreathingAndCameraTranslation() throws {
        let k0 = simd_float3x3(columns: (
            SIMD3<Float>(1500, 0, 0),
            SIMD3<Float>(0, 1500, 0),
            SIMD3<Float>(960, 720, 1)
        ))
        let kBreathing = simd_float3x3(columns: (
            SIMD3<Float>(1560, 0, 0),
            SIMD3<Float>(0, 1560, 0),
            SIMD3<Float>(960, 720, 1)
        ))
        let identity = matrix_identity_float4x4

        // Pure focus breathing (4% longer focal length) scales rim radius by 1.04x.
        let breathed = try #require(WaterCaptureGeometry.reprojectRim(
            rim0: [960, 720, 450],
            intrinsics0: k0,
            transform0: identity,
            openingDiameterCM: 6.8,
            intrinsicsK: kBreathing,
            transformK: identity
        ))
        #expect(abs(breathed[0] - 960) < 0.01)
        #expect(abs(breathed[1] - 720) < 0.01)
        #expect(abs(breathed[2] - 468) < 0.05)

        // Camera translates +0.01 m in +x (right): rim shifts left (-u) in image.
        var shifted = identity
        shifted.columns.3 = SIMD4<Float>(0.01, 0, 0, 1)
        let d0 = 1500.0 * 0.034 / 450.0
        let expectedShiftU = -1500.0 * 0.01 / d0
        let reprojected = try #require(WaterCaptureGeometry.reprojectRim(
            rim0: [960, 720, 450],
            intrinsics0: k0,
            transform0: identity,
            openingDiameterCM: 6.8,
            intrinsicsK: k0,
            transformK: shifted
        ))
        #expect(abs(reprojected[0] - (960 + expectedShiftU)) < 0.1)
        #expect(abs(reprojected[1] - 720) < 0.05)
        #expect(abs(reprojected[2] - 450) < 0.1)
    }

    @Test func sensorDisplayTransformRoundTripsUprightCoordinates() {
        let xform = SensorDisplayTransform(rawWidth: 1920, rawHeight: 1440)
        #expect(xform.displayWidth == 1440)
        #expect(xform.displayHeight == 1920)
        let samples = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 960, y: 720),
            CGPoint(x: 1234.5, y: 412.25),
            CGPoint(x: 1920, y: 1440)
        ]
        for raw in samples {
            let disp = xform.toDisplay(raw)
            let back = xform.toRaw(disp)
            #expect(abs(back.x - raw.x) < 1e-6)
            #expect(abs(back.y - raw.y) < 1e-6)
        }
        // Raw top-left (0,0) maps to upright top-right (1440, 0).
        let topLeftDisp = xform.toDisplay(CGPoint(x: 0, y: 0))
        #expect(abs(topLeftDisp.x - 1440) < 1e-6)
        #expect(abs(topLeftDisp.y - 0) < 1e-6)
    }

    @Test func solveWaterLevelMatchesCylinderPerspectiveFormula() throws {
        // Cylinder r=3.4 cm, H=20 cm, V=500 ml, d=12 cm, f=1200 px, true water height=10 cm.
        let observedR = 1200.0 * 3.4 / (12.0 + 20.0 - 10.0)
        let solved = try #require(WaterCaptureGeometry.solveWaterLevel(
            profileHeightsCM: [0, 20],
            profileRadiiCM: [3.4, 3.4],
            bottleHeightCM: 20,
            capacityML: 500,
            distanceCM: 12,
            focalLengthPx: 1200,
            observedRadiusPx: observedR
        ))
        #expect(abs(solved.heightCM - 10.0) < 1e-4)
        #expect(abs(solved.depthCM - 10.0) < 1e-4)
        #expect(abs(solved.remainingML - 250.0) < 0.05)

        // Ambiguous bottleneck profile returns nil rather than guessing.
        let ambiguous = WaterCaptureGeometry.solveWaterLevel(
            profileHeightsCM: [0, 10, 20],
            profileRadiiCM: [3.0, 2.0, 3.0],
            bottleHeightCM: 20,
            capacityML: 500,
            distanceCM: 10,
            focalLengthPx: 1000,
            observedRadiusPx: 100
        )
        #expect(ambiguous == nil)
    }

    @Test func healthExportFilterDeduplicatesAndRespectsEnabledDate() {
        let now = Date()
        let enabledAt = now.addingTimeInterval(-3600)
        let oldID = UUID()
        let syncedID = UUID()
        let inFlightID = UUID()
        let validID = UUID()
        let zeroID = UUID()

        let candidates: [HealthSyncFilter.ExportCandidate] = [
            .init(id: oldID, amountML: 250, timestamp: enabledAt.addingTimeInterval(-60)),
            .init(id: syncedID, amountML: 250, timestamp: now),
            .init(id: inFlightID, amountML: 250, timestamp: now),
            .init(id: zeroID, amountML: 0, timestamp: now),
            .init(id: validID, amountML: 350, timestamp: now)
        ]

        let result = HealthSyncFilter.exportableRecords(
            candidates,
            enabledAt: enabledAt,
            syncedIDs: [syncedID.uuidString],
            inFlightIDs: [inFlightID.uuidString]
        )

        #expect(result.map(\.id) == [validID])
    }

    @Test func healthImportFilterSkipsOwnBundleAndPreventsFeedbackLoop() {
        let now = Date()
        let ownSample = UUID()
        let existingSample = UUID()
        let alreadyImported = UUID()
        let externalSample = UUID()

        let samples: [HealthSyncFilter.ExternalSampleCandidate] = [
            .init(uuid: ownSample, amountML: 250, startDate: now, sourceBundleID: "benjaminshih.Flux"),
            .init(uuid: existingSample, amountML: 200, startDate: now, sourceBundleID: "com.apple.Health"),
            .init(uuid: alreadyImported, amountML: 300, startDate: now, sourceBundleID: "com.apple.Health"),
            .init(uuid: externalSample, amountML: 400, startDate: now, sourceBundleID: "com.other.Hydration")
        ]

        let importable = HealthSyncFilter.importableExternalSamples(
            samples,
            ownBundleID: "benjaminshih.Flux",
            existingRecordIDs: [existingSample],
            importedIDs: [alreadyImported.uuidString]
        )

        #expect(importable.map(\.uuid) == [externalSample])
    }

    @Test func watchHydrationCodecParsesEventsTimestampsAndSnapshots() throws {
        let now = Date(timeIntervalSince1970: 1_763_720_000)
        let eventID = UUID()
        let twoHoursAgo = now.addingTimeInterval(-7200)

        let added = try #require(WatchHydrationCodec.parseWaterAdded([
            "type": "water_added",
            "event_id": eventID.uuidString,
            "amount_ml": 250,
            "timestamp": twoHoursAgo.timeIntervalSince1970
        ], now: now))
        #expect(added.id == eventID)
        #expect(added.amountML == 250)
        #expect(abs(added.timestamp.timeIntervalSince(twoHoursAgo)) < 0.01)

        // Future corrupt timestamps clamp to `now`.
        let futureAdded = try #require(WatchHydrationCodec.parseWaterAdded([
            "type": "water_added",
            "event_id": eventID.uuidString,
            "amount_ml": 150,
            "timestamp": now.addingTimeInterval(3600).timeIntervalSince1970
        ], now: now))
        #expect(abs(futureAdded.timestamp.timeIntervalSince(now)) < 0.01)

        // Invalid amount rejected.
        #expect(WatchHydrationCodec.parseWaterAdded([
            "type": "water_added",
            "event_id": eventID.uuidString,
            "amount_ml": 0
        ], now: now) == nil)

        // Undo event parsing.
        let deletedID = WatchHydrationCodec.parseWaterDeleted([
            "type": "water_deleted",
            "event_id": eventID.uuidString
        ])
        #expect(deletedID == eventID)

        // Snapshot payload contains dynamic goal, energy, streak, day key, and entries.
        let snapshot = WatchHydrationCodec.makeSnapshotPayload(
            totalML: 1250,
            goalML: 2300,
            activeEnergyKCal: 300,
            streakDays: 4,
            recentEntries: [(eventID, 250, twoHoursAgo)],
            now: now
        )
        #expect(snapshot["today_total_ml"] as? Int == 1250)
        #expect(snapshot["goal_ml"] as? Int == 2300)
        #expect(snapshot["active_energy_kcal"] as? Int == 300)
        #expect(snapshot["streak_days"] as? Int == 4)
        #expect((snapshot["day_key"] as? String)?.count == 10)
        let recent = try #require(snapshot["recent_entries"] as? [[String: Any]])
        #expect(recent.count == 1)
        #expect(recent[0]["id"] as? String == eventID.uuidString)
    }

    @Test @MainActor func dynamicGoalEngineAdjustsForWorkoutEnergyAndHeatSafely() {
        let engine = DynamicGoalEngine()
        engine.baseGoalML = 2000
        #expect(engine.calculateTodayGoal(activeEnergyKCal: 350, apparentTempCelsius: 30.0) == 2550)
        #expect(engine.calculateTodayGoal(activeEnergyKCal: 5000, apparentTempCelsius: 40.0) == 5000)
    }

}
