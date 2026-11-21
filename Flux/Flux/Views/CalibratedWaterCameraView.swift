import SwiftUI
@preconcurrency import AVFoundation
import CoreImage
import CoreMotion
import simd

/// One focus-swept frame captured at an explicit hardware lens position.
struct FocusBracketFrame {
    let image: UIImage
    let rim: [Double]
    let focalLengthPixels: Double
    let lensPosition: Float
}

/// The base capture plus hardware-locked interior focus sweep frames.
/// Pixels remain in raw landscape-right rear-camera sensor orientation.
struct CalibratedWaterCapture {
    let image: UIImage
    let focalLengthPixels: Double
    let alignmentScore: Double
    let capturedAt: Date
    let rim: [Double]
    let frameTimestamp: TimeInterval
    let rimLensPosition: Float?
    let focusFrames: [FocusBracketFrame]

    init(
        image: UIImage,
        focalLengthPixels: Double,
        alignmentScore: Double,
        capturedAt: Date,
        rim: [Double],
        frameTimestamp: TimeInterval,
        rimLensPosition: Float? = nil,
        focusFrames: [FocusBracketFrame] = []
    ) {
        self.image = image
        self.focalLengthPixels = focalLengthPixels
        self.alignmentScore = alignmentScore
        self.capturedAt = capturedAt
        self.rim = rim
        self.frameTimestamp = frameTimestamp
        self.rimLensPosition = rimLensPosition
        self.focusFrames = focusFrames
    }
}

/// Maps between raw landscape-right rear-camera sensor pixels and upright
/// portrait display coordinates (90 degrees clockwise).
struct SensorDisplayTransform: Equatable {
    let rawWidth: Double
    let rawHeight: Double

    var displayWidth: Double { rawHeight }
    var displayHeight: Double { rawWidth }

    func toDisplay(_ rawPoint: CGPoint) -> CGPoint {
        CGPoint(x: rawHeight - Double(rawPoint.y), y: Double(rawPoint.x))
    }

    func toRaw(_ displayPoint: CGPoint) -> CGPoint {
        CGPoint(x: Double(displayPoint.y), y: rawHeight - Double(displayPoint.x))
    }
}

enum WaterCaptureGeometry {
    static func focalLength(fx: Double, fy: Double) -> Double? {
        guard fx.isFinite, fy.isFinite, fx > 0, fy > 0,
              abs(fx - fy) / max(fx, fy) < 0.01 else { return nil }
        return (fx + fy) / 2
    }

    /// Camera +z points out of the screen; it equals +1 (or -gravity.z) when looking straight down.
    static func alignmentScore(cameraZWorldY: Double) -> Double {
        guard cameraZWorldY.isFinite else { return 0 }
        let tilt = acos(min(1, max(-1, cameraZWorldY))) * 180 / .pi
        guard tilt <= 5 else { return 0 }
        return max(0, 1 - tilt / 30)
    }

    /// Hardware lens sweep covering rim (~12 cm) through deep bottle interiors (~60+ cm).
    static func fullInteriorLensSweep() -> [Float] {
        [0.18, 0.32, 0.46, 0.60, 0.73, 0.85]
    }

    /// Choose lens positions strictly farther than the rim so the water surface
    /// at any depth inside the bottle falls within at least one sharp focus band.
    static func interiorLensPositions(rimLensPosition: Float, steps: Int = 5) -> [Float] {
        guard steps > 0 else { return [] }
        let clampedRim = min(max(rimLensPosition, 0.0), 0.72)
        let low = min(0.74, max(clampedRim + 0.10, 0.22))
        let high = min(0.90, max(low + 0.14, 0.82))
        if steps == 1 { return [low] }
        return (0..<steps).map { idx in
            let t = Float(idx) / Float(steps - 1)
            return low + t * (high - low)
        }
    }

    /// Reproject a rim circle between two calibrated camera poses and intrinsics.
    static func reprojectRim(
        rim0: [Double],
        intrinsics0: simd_float3x3,
        transform0: simd_float4x4,
        openingDiameterCM: Double,
        intrinsicsK: simd_float3x3,
        transformK: simd_float4x4
    ) -> [Double]? {
        guard rim0.count == 3, openingDiameterCM > 0.5, openingDiameterCM < 25 else { return nil }
        let cx0 = rim0[0], cy0 = rim0[1], r0 = rim0[2]
        guard r0 > 10,
              let f0 = focalLength(fx: Double(intrinsics0.columns.0.x), fy: Double(intrinsics0.columns.1.y)),
              let fK = focalLength(fx: Double(intrinsicsK.columns.0.x), fy: Double(intrinsicsK.columns.1.y))
        else { return nil }

        let openingRadiusM = (openingDiameterCM / 2.0) / 100.0
        let d0 = f0 * openingRadiusM / r0
        guard d0.isFinite, d0 > 0.03, d0 < 0.80 else { return nil }

        let fx0 = Double(intrinsics0.columns.0.x)
        let fy0 = Double(intrinsics0.columns.1.y)
        let px0 = Double(intrinsics0.columns.2.x)
        let py0 = Double(intrinsics0.columns.2.y)

        let pCam0 = SIMD4<Float>(
            Float((cx0 - px0) / fx0 * d0),
            Float(-(cy0 - py0) / fy0 * d0),
            Float(-d0),
            1.0
        )
        let pWorld = transform0 * pCam0
        let pCamK = transformK.inverse * pWorld
        let dK = Double(-pCamK.z)
        guard dK.isFinite, dK > 0.03, dK < 0.80 else { return nil }

        let fxK = Double(intrinsicsK.columns.0.x)
        let fyK = Double(intrinsicsK.columns.1.y)
        let pxK = Double(intrinsicsK.columns.2.x)
        let pyK = Double(intrinsicsK.columns.2.y)

        let uK = pxK + fxK * Double(pCamK.x) / dK
        let vK = pyK - fyK * Double(pCamK.y) / dK
        let rK = r0 * (fK / f0) * (d0 / dK)
        guard uK.isFinite, vK.isFinite, rK.isFinite, rK > 10 else { return nil }
        return [uK, vK, rK]
    }

    /// Solve f * r(h) / (d + H - h) = observedRadiusPx for a unique surface height.
    /// Matches backend `estimators.perspective_height` so live UI adjustment agrees
    /// with server calculation.
    static func perspectiveHeight(
        profileHeightsCM: [Double],
        profileRadiiCM: [Double],
        bottleHeightCM: Double,
        distanceCM: Double,
        focalLengthPx: Double,
        observedRadiusPx: Double
    ) -> Double? {
        guard profileHeightsCM.count >= 2,
              profileHeightsCM.count == profileRadiiCM.count,
              bottleHeightCM.isFinite, bottleHeightCM > 0,
              distanceCM.isFinite, distanceCM > 0,
              focalLengthPx.isFinite, focalLengthPx > 0,
              observedRadiusPx.isFinite, observedRadiusPx > 0
        else { return nil }

        var candidates: [Double] = []
        for idx in 0..<(profileHeightsCM.count - 1) {
            let h0 = profileHeightsCM[idx]
            let r0 = profileRadiiCM[idx]
            let h1 = profileHeightsCM[idx + 1]
            let r1 = profileRadiiCM[idx + 1]
            guard h1 > h0 else { continue }
            let slope = (r1 - r0) / (h1 - h0)
            let intercept = r0 - slope * h0
            let denominator = focalLengthPx * slope + observedRadiusPx
            let numerator = observedRadiusPx * (distanceCM + bottleHeightCM) - focalLengthPx * intercept
            if abs(denominator) < 1e-8 {
                if abs(numerator) < 1e-8 { return nil }
                continue
            }
            let height = numerator / denominator
            if h0 - 1e-6 <= height && height <= h1 + 1e-6 {
                if candidates.isEmpty || abs(height - candidates[candidates.count - 1]) > 1e-6 {
                    candidates.append(height)
                }
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func solveWaterLevel(
        profileHeightsCM: [Double],
        profileRadiiCM: [Double],
        bottleHeightCM: Double,
        capacityML: Double,
        distanceCM: Double,
        focalLengthPx: Double,
        observedRadiusPx: Double
    ) -> (heightCM: Double, depthCM: Double, remainingML: Double)? {
        guard let rawHeight = perspectiveHeight(
            profileHeightsCM: profileHeightsCM,
            profileRadiiCM: profileRadiiCM,
            bottleHeightCM: bottleHeightCM,
            distanceCM: distanceCM,
            focalLengthPx: focalLengthPx,
            observedRadiusPx: observedRadiusPx
        ) else { return nil }

        let heightCM = min(bottleHeightCM, max(0, rawHeight))
        let depthCM = max(0, bottleHeightCM - heightCM)
        let pairs = zip(profileHeightsCM, profileRadiiCM).map { (height: $0, radius: $1) }
        let total = BottleVolumeCalculator.totalVolumeML(profile: pairs)
        guard total > 0 else { return nil }
        let below = BottleVolumeCalculator.volumeBelowHeight(profile: pairs, waterHeightCM: heightCM)
        let remainingML = min(capacityML, max(0, below / total * capacityML))
        return (heightCM, depthCM, remainingML)
    }
}

/// Snapshot of one raw camera video frame with calibrated focal length and lens position.
private struct LiveSensorFrame {
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    let focalLengthPx: Double
    let lensPosition: Float
    let uptime: TimeInterval
}

/// Direct AVFoundation + CoreMotion capture controller.
/// Unlike ARSession (which ignores or overrides manual focus locks and drifts
/// VIO when looking straight down at a symmetrical bottle), owning
/// AVCaptureSession directly guarantees hardware-accurate `lensPosition`
/// sweeps inside the bottle interior.
private final class WaterCameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private let sessionQueue = DispatchQueue(label: "flux.water.camera.session")
    private let videoQueue = DispatchQueue(label: "flux.water.camera.video", qos: .userInteractive)
    private let motionManager = CMMotionManager()
    private let frameLock = NSLock()

    private var captureDevice: AVCaptureDevice?
    private var latestFrame: LiveSensorFrame?
    private var isConfigured = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Default interior preview focus (~22-26 cm): water is sharp while aiming,
    // and the high-contrast rim still locks reliably.
    private static let previewInteriorLensPosition: Float = 0.46

    func start() {
        startMotionUpdates()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
            self.applyLockedLensPositionSync(Self.previewInteriorLensPosition)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates()
    }

    func currentMotionState() -> (alignmentScore: Double, isSteady: Bool) {
        guard let motion = motionManager.deviceMotion else {
            return (0, false)
        }
        // When the iPhone screen faces up and the rear camera looks straight down,
        // CoreMotion gravity.z approaches -1.0.
        let score = WaterCaptureGeometry.alignmentScore(cameraZWorldY: -motion.gravity.z)
        let r = motion.rotationRate
        let a = motion.userAcceleration
        let rotMag = hypot(hypot(r.x, r.y), r.z)
        let accMag = hypot(hypot(a.x, a.y), a.z)
        let steady = rotMag < 0.32 && accMag < 0.09
        return (score, steady)
    }

    func latestSnapshot() -> LiveSensorFrame? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }

    func currentLensPosition() -> Float? {
        captureDevice?.lensPosition
    }

    func makeUIImage(from buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Move hardware focus to `target` with smooth-autofocus disabled and verify
    /// that `device.lensPosition` physically reaches `target`.
    func setHardwareLensPosition(_ target: Float) async -> Bool {
        let clamped = min(max(target, 0.0), 1.0)
        guard let device = captureDevice, device.isFocusModeSupported(.locked) else { return false }

        let lockCompleted: Bool = await withCheckedContinuation { continuation in
            let guardLock = NSLock()
            var resumed = false
            func finish(_ ok: Bool) {
                guardLock.lock()
                defer { guardLock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: ok)
            }

            sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    if device.isSmoothAutoFocusSupported {
                        device.isSmoothAutoFocusEnabled = false
                    }
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.setFocusModeLocked(lensPosition: clamped) { _ in
                        finish(true)
                    }
                    device.unlockForConfiguration()
                } catch {
                    finish(false)
                    return
                }

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25) {
                    finish(true)
                }
            }
        }

        guard lockCompleted else { return false }

        // Poll briefly until the voice-coil motor physically settles near `clamped`.
        for _ in 0..<10 {
            if abs(device.lensPosition - clamped) <= 0.035 {
                return true
            }
            do { try await Task.sleep(for: .milliseconds(18)) } catch { return false }
        }
        return abs(device.lensPosition - clamped) <= 0.07
    }

    func restoreInteriorPreviewFocus() {
        sessionQueue.async { [weak self] in
            self?.applyLockedLensPositionSync(Self.previewInteriorLensPosition)
        }
    }

    private func applyLockedLensPositionSync(_ position: Float) {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = false
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isFocusModeSupported(.locked) {
                device.setFocusModeLocked(lensPosition: min(max(position, 0.0), 1.0), completionHandler: nil)
            }
        } catch {}
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // `.photo` selects the full 4:3 wide-angle sensor field of view without 16:9 cropping.
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        } else {
            session.sessionPreset = .high
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)
        captureDevice = device

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }

        isConfigured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        var focalPx: Double?
        if let attachment = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ) as? Data, attachment.count >= MemoryLayout<simd_float3x3>.size {
            let matrix = attachment.withUnsafeBytes { $0.loadUnaligned(as: simd_float3x3.self) }
            focalPx = WaterCaptureGeometry.focalLength(
                fx: Double(matrix.columns.0.x),
                fy: Double(matrix.columns.1.y)
            )
        }

        if focalPx == nil, let device = captureDevice {
            let fovDeg = Double(device.activeFormat.videoFieldOfView)
            if fovDeg > 10, fovDeg < 140 {
                let halfRad = (fovDeg * .pi / 180.0) / 2.0
                focalPx = (Double(width) / 2.0) / tan(halfRad)
            }
        }
        guard let resolvedFocal = focalPx else { return }

        let snapshot = LiveSensorFrame(
            pixelBuffer: pixelBuffer,
            width: width,
            height: height,
            focalLengthPx: resolvedFocal,
            lensPosition: captureDevice?.lensPosition ?? 0.46,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        frameLock.lock()
        latestFrame = snapshot
        frameLock.unlock()
    }
}

private final class CameraPreviewHostView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct WaterCameraPreview: UIViewRepresentable {
    let controller: WaterCameraController

    func makeUIView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.backgroundColor = .black
        view.previewLayer.session = controller.session
        view.previewLayer.videoGravity = .resizeAspectFill
        controller.previewLayer = view.previewLayer
        return view
    }

    func updateUIView(_ uiView: CameraPreviewHostView, context: Context) {
        if uiView.previewLayer.session !== controller.session {
            uiView.previewLayer.session = controller.session
        }
        controller.previewLayer = uiView.previewLayer
    }
}

struct CalibratedWaterCameraView: View {
    let hasBottle: Bool
    let bottleOpeningDiameterCM: Double?
    let onCapture: (CalibratedWaterCapture) async -> String?

    init(
        hasBottle: Bool,
        bottleOpeningDiameterCM: Double? = nil,
        onCapture: @escaping (CalibratedWaterCapture) async -> String?
    ) {
        self.hasBottle = hasBottle
        self.bottleOpeningDiameterCM = bottleOpeningDiameterCM
        self.onCapture = onCapture
    }

    @State private var controller = WaterCameraController()
    @State private var permitted = false
    @State private var detectedCircle: CGRect?
    @State private var aligned = false
    @State private var sweepingFocus = false
    @State private var message = "正在開啟相機…"

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let radius = min(size.width, size.height) * 0.32
            ZStack {
                Color.black
                if permitted { WaterCameraPreview(controller: controller) }
                Circle()
                    .stroke(.white.opacity(aligned ? 0.35 : 0.9), lineWidth: 2)
                    .frame(width: radius * 2, height: radius * 2)
                if aligned, let circle = detectedCircle {
                    Circle()
                        .stroke(sweepingFocus ? Color.cyan : Color.green, lineWidth: 3)
                        .frame(width: circle.width, height: circle.height)
                        .position(x: circle.midX, y: circle.midY)
                }
                VStack {
                    Spacer()
                    Text(message)
                        .font(.subheadline.bold())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.76), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(10)
            }
            .task(id: size) {
                permitted = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled else { return }
                guard permitted else {
                    message = "請在系統設定允許 Flux 使用相機。"
                    return
                }
                controller.start()
                await monitor(size: size, radius: radius)
            }
        }
        .onDisappear { controller.stop() }
    }

    @MainActor
    private func monitor(size: CGSize, radius: CGFloat) async {
        var steadyStart: TimeInterval?
        var previousUptime = -1.0
        var anchorRim: [Double]?
        var waitForReposition = false

        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            guard hasBottle else { message = "請先建立水瓶"; continue }
            guard let previewLayer = controller.previewLayer,
                  let snap = controller.latestSnapshot(),
                  snap.uptime != previousUptime,
                  ProcessInfo.processInfo.systemUptime - snap.uptime < 0.35,
                  size.width > 0, size.height > 0 else {
                aligned = false; steadyStart = nil; message = "等待相機就緒…"; continue
            }
            previousUptime = snap.uptime

            let motion = controller.currentMotionState()
            guard motion.alignmentScore >= 0.82 else {
                aligned = false; steadyStart = nil; message = "請保持手機水平，鏡頭朝下"; continue
            }

            // Convert SwiftUI guide circle into raw sensor pixel coordinates via AVFoundation preview layer.
            let viewCenter = CGPoint(x: size.width / 2, y: size.height / 2)
            let viewEdge = CGPoint(x: size.width / 2 + radius, y: size.height / 2)
            let devCenter = previewLayer.captureDevicePointConverted(fromLayerPoint: viewCenter)
            let devEdge = previewLayer.captureDevicePointConverted(fromLayerPoint: viewEdge)
            let w = Double(snap.width), h = Double(snap.height)
            let guideX = Double(devCenter.x) * w
            let guideY = Double(devCenter.y) * h
            let guideR = hypot((Double(devEdge.x) - Double(devCenter.x)) * w, (Double(devEdge.y) - Double(devCenter.y)) * h)

            guard let rim = Self.alignedRim(snap.pixelBuffer, x: guideX, y: guideY, radius: guideR) else {
                waitForReposition = false
                aligned = false; steadyStart = nil; message = "將瓶口內緣對齊白色圓框"; continue
            }

            if waitForReposition {
                // Wait for user to slightly move away before auto-retriggering after a retake hint.
                if let prev = anchorRim, hypot(prev[0] - rim[0], prev[1] - rim[1]) < guideR * 0.12 {
                    continue
                }
                waitForReposition = false
            }

            let rimDevPt = CGPoint(x: rim[0] / w, y: rim[1] / h)
            let rimViewPt = previewLayer.layerPointConverted(fromCaptureDevicePoint: rimDevPt)
            let viewRadius = radius * rim[2] / max(guideR, 1)
            detectedCircle = CGRect(
                x: rimViewPt.x - viewRadius,
                y: rimViewPt.y - viewRadius,
                width: 2 * viewRadius,
                height: 2 * viewRadius
            )

            let changedRing = anchorRim.map {
                hypot($0[0] - rim[0], $0[1] - rim[1]) > guideR * 0.055 || abs($0[2] - rim[2]) > guideR * 0.035
            } ?? true

            if steadyStart == nil || changedRing || !motion.isSteady {
                anchorRim = rim
                steadyStart = snap.uptime
            }
            aligned = true
            message = "已對齊，保持穩定…"

            if snap.uptime - (steadyStart ?? snap.uptime) >= 0.45 {
                if let capture = await performHardwareFocusSweep(
                    initialRim: rim,
                    guideX: guideX,
                    guideY: guideY,
                    guideR: guideR
                ) {
                    message = "正在挑選最清晰水面焦段並辨識…"
                    guard let hint = await onCapture(capture) else { return }
                    aligned = false
                    message = hint
                    waitForReposition = true
                }
                steadyStart = nil
            }
        }
    }

    /// Sweep 6 real hardware lens positions from rim (~12 cm) through deep bottle
    /// interior (~60+ cm), verifying that `device.lensPosition` physically reaches
    /// every target before grabbing a fresh frame.
    @MainActor
    private func performHardwareFocusSweep(
        initialRim: [Double],
        guideX: Double,
        guideY: Double,
        guideR: Double
    ) async -> CalibratedWaterCapture? {
        sweepingFocus = true
        defer {
            sweepingFocus = false
            controller.restoreInteriorPreviewFocus()
        }

        let sweepTargets = WaterCaptureGeometry.fullInteriorLensSweep()
        var collected: [(image: UIImage, rim: [Double], focal: Double, lensPos: Float, score: Double, uptime: TimeInterval)] = []
        var lastCenterX = initialRim[0]
        var lastCenterY = initialRim[1]
        var lastRadius = initialRim[2]
        var lastFocal: Double?

        for (idx, targetLP) in sweepTargets.enumerated() {
            guard !Task.isCancelled else { break }
            message = "對焦掃描瓶內水面 (\(idx + 1)/\(sweepTargets.count))…"

            let reached = await controller.setHardwareLensPosition(targetLP)
            guard reached, !Task.isCancelled else { continue }

            // Wait for a fresh frame captured strictly AFTER hardware focus settled.
            let settledUptime = ProcessInfo.processInfo.systemUptime
            var freshSnap: LiveSensorFrame?
            for _ in 0..<10 {
                if let snap = controller.latestSnapshot(), snap.uptime > settledUptime + 0.015 {
                    freshSnap = snap
                    break
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
            guard let snap = freshSnap else { continue }

            let motion = controller.currentMotionState()
            guard motion.alignmentScore >= 0.76 else { continue }

            // Re-fit rim directly on this frame's luma pixels (fallback to focal-scaled rim if soft at deep focus).
            let approxR = lastFocal.map { lastRadius * (snap.focalLengthPx / $0) } ?? lastRadius
            let fittedRim = Self.alignedRim(snap.pixelBuffer, x: lastCenterX, y: lastCenterY, radius: approxR)
                ?? Self.alignedRim(snap.pixelBuffer, x: guideX, y: guideY, radius: guideR)
                ?? [lastCenterX, lastCenterY, approxR]

            guard fittedRim[2] >= 24,
                  fittedRim[0] >= fittedRim[2], fittedRim[0] < Double(snap.width) - fittedRim[2],
                  fittedRim[1] >= fittedRim[2], fittedRim[1] < Double(snap.height) - fittedRim[2],
                  let img = controller.makeUIImage(from: snap.pixelBuffer) else { continue }

            lastCenterX = fittedRim[0]
            lastCenterY = fittedRim[1]
            lastRadius = fittedRim[2]
            lastFocal = snap.focalLengthPx

            collected.append((
                image: img,
                rim: fittedRim,
                focal: snap.focalLengthPx,
                lensPos: snap.lensPosition,
                score: motion.alignmentScore,
                uptime: snap.uptime
            ))
        }

        guard let first = collected.first else {
            message = "焦段掃描期間晃動過大，請保持穩定重試。"
            return nil
        }

        let extraFrames = collected.dropFirst().map { item in
            FocusBracketFrame(
                image: item.image,
                rim: item.rim,
                focalLengthPixels: item.focal,
                lensPosition: item.lensPos
            )
        }

        return CalibratedWaterCapture(
            image: first.image,
            focalLengthPixels: first.focal,
            alignmentScore: first.score,
            capturedAt: Date(),
            rim: first.rim,
            frameTimestamp: first.uptime,
            rimLensPosition: first.lensPos,
            focusFrames: extraFrames
        )
    }

    // Check a narrow annulus around the user's guide in the sensor luma plane.
    static func alignedRim(_ buffer: CVPixelBuffer, x: Double, y: Double, radius: Double) -> [Double]? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1, radius >= 20 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        // Sample circles around the guide. Opposite sides must support the
        // same contrast direction, so unrelated bright arcs cannot vote together.
        let directions = (0..<48).map { i in
            let a = Double(i) * .pi / 24
            return SIMD2(cos(a), sin(a))
        }
        let margin = radius * 1.14 + 5
        guard x >= margin, y >= margin, x + margin < Double(width), y + margin < Double(height) else { return nil }
        var bestScore = -Double.infinity
        var best: [Double]?
        for sx in -2...2 {
            for sy in -2...2 {
                let cx = x + Double(sx) * radius * 0.022
                let cy = y + Double(sy) * radius * 0.022
                for step in -5...5 {
                    let r = radius * (1 + Double(step) * 0.012)
                    var positive = SIMD8<Float>.zero
                    var negative = SIMD8<Float>.zero
                    var lip = SIMD8<Float>.zero
                    var support = 0.0
                    for (i, dir) in directions.enumerated() {
                        func value(_ d: Double) -> Int {
                            Int(pixels[Int((cy + dir.y * d).rounded()) * stride + Int((cx + dir.x * d).rounded())])
                        }
                        let gradient = value(r + 3) - value(r - 3)
                        guard abs(gradient) >= 14 else { continue }
                        if gradient > 0 { positive[i / 6] += 1 } else { negative[i / 6] += 1 }
                        // An inner lip often borders a narrow band. Look
                        // outward for its opposite edge on the same ray.
                        let band = max(6, r * 0.025)
                        let outside = value(r + 3)
                        for offset in 1...3 {
                            let change = outside - value(r + Double(offset) * band)
                            if change * gradient > 0 && abs(change) >= 14 {
                                lip[i / 6] += 1
                                break
                            }
                        }
                        support += min(1, Double(abs(gradient)) / 60)
                    }
                    let votes = positive + negative
                    let polarity = max(positive.sum(), negative.sum())
                    guard votes.min() >= 2, votes.sum() >= 31, polarity >= 28 else { continue }
                    let lipSupport = lip.min() >= 1 ? Double(lip.sum()) : 0
                    let score = Double(polarity) + support * 0.25 + lipSupport * 1.2
                        - 0.8 * hypot(Double(sx), Double(sy)) - 0.6 * Double(abs(step))
                    if score > bestScore {
                        bestScore = score
                        best = [cx, cy, r]
                    }
                }
            }
        }
        return best
    }
}
