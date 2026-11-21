import SwiftUI
import ARKit
import RealityKit
import CoreImage
import AVFoundation

/// The JPEG, focal length and gravity alignment come from one ARFrame.
/// Pixels remain in the raw sensor orientation (no crop, resize or EXIF rotation).
struct CalibratedWaterCapture {
    let image: UIImage
    let focalLengthPixels: Double
    let alignmentScore: Double
    let capturedAt: Date
    let rim: [Double]
    let frameTimestamp: TimeInterval
}

enum WaterCaptureGeometry {
    static func focalLength(fx: Double, fy: Double) -> Double? {
        guard fx.isFinite, fy.isFinite, fx > 0, fy > 0,
              abs(fx - fy) / max(fx, fy) < 0.01 else { return nil }
        return (fx + fy) / 2
    }

    /// AR camera +z points out of the screen; it points up when looking down.
    static func alignmentScore(cameraZWorldY: Double) -> Double {
        guard cameraZWorldY.isFinite else { return 0 }
        let tilt = acos(min(1, max(-1, cameraZWorldY))) * 180 / .pi
        guard tilt <= 5 else { return 0 }
        return max(0, 1 - tilt / 30)
    }
}

struct CalibratedWaterCameraView: View {
    let hasBottle: Bool
    let onCapture: (CalibratedWaterCapture) async -> String?
    @State private var session = ARSession()
    @State private var permitted = false
    @State private var detectedCircle: CGRect?
    @State private var aligned = false
    @State private var message = "正在開啟相機…"

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let radius = min(size.width, size.height) * 0.32
            ZStack {
                Color.black
                if permitted { WaterCameraPreview(session: session) }
                Circle()
                    .stroke(.white.opacity(aligned ? 0.35 : 0.9), lineWidth: 2)
                    .frame(width: radius * 2, height: radius * 2)
                if aligned, let circle = detectedCircle {
                    Circle().stroke(.green, lineWidth: 3)
                        .frame(width: circle.width, height: circle.height)
                        .position(x: circle.midX, y: circle.midY)
                }
                VStack {
                    Spacer()
                    Text(message).font(.subheadline.bold())
                        .padding(10).background(.black.opacity(0.72), in: Capsule())
                        .foregroundStyle(.white)
                }.padding(10)
            }
            .task(id: size) {
                guard ARWorldTrackingConfiguration.isSupported else {
                    message = "此裝置無法使用 AR 相機。"
                    return
                }
                permitted = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled else { return }
                guard permitted else {
                    message = "請在系統設定允許 Flux 使用相機。"
                    return
                }
                await monitor(size: size, radius: radius)
            }
        }
        .onDisappear { session.pause() }
    }

    @MainActor
    private func monitor(size: CGSize, radius: CGFloat) async {
        var start: TimeInterval?
        var anchor = SIMD3<Float>.zero
        var retryLocation: SIMD3<Float>?
        var retriedInPlace = false
        var previous = -1.0
        var anchorRim: [Double]?
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard hasBottle else { message = "請先建立水瓶"; continue }
            guard let frame = session.currentFrame, frame.timestamp != previous,
                  ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.25,
                  case .normal = frame.camera.trackingState,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
                  size.width > 0, size.height > 0 else {
                aligned = false; start = nil; message = "等待相機就緒…"; continue
            }
            previous = frame.timestamp
            let pos = frame.camera.transform.columns.3
            let location = SIMD3(pos.x, pos.y, pos.z)
            let score = WaterCaptureGeometry.alignmentScore(cameraZWorldY: Double(frame.camera.transform.columns.2.y))
            guard score >= 0.82 else {
                aligned = false; start = nil; message = "請保持手機水平，鏡頭朝下"; continue
            }
            let inverse = frame.displayTransform(for: scene.effectiveGeometry.interfaceOrientation, viewportSize: size).inverted()
            let center = CGPoint(x: 0.5, y: 0.5).applying(inverse)
            let edge = CGPoint(x: 0.5 + radius / size.width, y: 0.5).applying(inverse)
            let res = frame.camera.imageResolution
            let r = hypot((edge.x-center.x)*res.width, (edge.y-center.y)*res.height)
            guard let rim = Self.alignedRim(frame.capturedImage, x: center.x*res.width, y: center.y*res.height, radius: r) else {
                retryLocation = nil
                retriedInPlace = false
                aligned = false; start = nil; message = "將瓶口內緣對齊白色圓框"; continue
            }
            if let retryLocation {
                guard simd_distance(location, retryLocation) >= 0.01 else { continue }
                retriedInPlace = false
            }
            retryLocation = nil
            let viewPoint = CGPoint(x: rim[0]/res.width, y: rim[1]/res.height).applying(inverse.inverted())
            let viewRadius = radius * rim[2] / r
            detectedCircle = CGRect(x: viewPoint.x * size.width - viewRadius, y: viewPoint.y * size.height - viewRadius,
                                    width: 2 * viewRadius, height: 2 * viewRadius)
            let changedRing = anchorRim.map {
                hypot($0[0]-rim[0], $0[1]-rim[1]) > r*0.055 || abs($0[2]-rim[2]) > r*0.035
            } ?? true
            if start == nil || changedRing || simd_distance(location, anchor) > 0.004 {
                anchorRim = rim
                start = frame.timestamp
                anchor = location
            }
            aligned = true
            message = "已對齊，保持穩定…"
            if frame.timestamp - (start ?? frame.timestamp) >= 0.45 {
                if let photo = capture(frame, score: score, rim: rim) {
                    message = "正在估算水量…"
                    guard let hint = await onCapture(photo) else { return }
                    aligned = false
                    message = hint
                    if retriedInPlace {
                        retryLocation = location
                    } else {
                        retriedInPlace = true
                        message = "正在重新確認水面，請保持對齊…"
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    }
                }
                start = nil
            }
        }
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
                            Int(pixels[Int((cy + dir.y*d).rounded()) * stride + Int((cx + dir.x*d).rounded())])
                        }
                        let gradient = value(r+3) - value(r-3)
                        guard abs(gradient) >= 14 else { continue }
                        if gradient > 0 { positive[i/6] += 1 } else { negative[i/6] += 1 }
                        // An inner lip often borders a narrow band. Look
                        // outward for its opposite edge on the same ray.
                        let band = max(6, r*0.025)
                        let outside = value(r+3)
                        for offset in 1...3 {
                            let change = outside - value(r + Double(offset)*band)
                            if change * gradient > 0 && abs(change) >= 14 {
                                lip[i/6] += 1
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

    private func capture(_ frame: ARFrame, score: Double, rim: [Double]) -> CalibratedWaterCapture? {
        let buffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let resolution = frame.camera.imageResolution
        guard width == Int(resolution.width), height == Int(resolution.height),
              let focal = WaterCaptureGeometry.focalLength(
                fx: Double(frame.camera.intrinsics.columns.0.x),
                fy: Double(frame.camera.intrinsics.columns.1.y)
              ) else {
            message = "這個影格缺少一致的相機校正資料，請重新擷取。"
            return nil
        }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
            message = "無法取得影像，請重試。"
            return nil
        }
        return CalibratedWaterCapture(
            image: UIImage(cgImage: cgImage, scale: 1, orientation: .up),
            focalLengthPixels: focal,
            alignmentScore: score,
            capturedAt: Date(),
            rim: rim,
            frameTimestamp: frame.timestamp
        )
    }
}

private struct WaterCameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        if ARWorldTrackingConfiguration.isSupported {
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            session.run(configuration)
        }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
