import SwiftUI
import ARKit
import RealityKit
import CoreImage

/// The JPEG, focal length and gravity alignment come from one ARFrame.
/// Pixels remain in the raw sensor orientation (no crop, resize or EXIF rotation).
struct CalibratedWaterCapture {
    let image: UIImage
    let focalLengthPixels: Double
    let alignmentScore: Double
    let capturedAt: Date
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
    let onCapture: (CalibratedWaterCapture) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var session = ARSession()
    @State private var message = "從瓶口正上方拍攝，保持手機水平並稍停片刻。"

    var body: some View {
        ZStack {
            WaterCameraPreview(session: session).ignoresSafeArea()
            VStack {
                HStack {
                    Button("取消") { dismiss() }
                    Spacer()
                }
                Spacer()
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.black.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Button("擷取量測影格", action: capture)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .foregroundStyle(.white)
            .padding()
        }
        .onDisappear { session.pause() }
    }

    private func capture() {
        guard ARWorldTrackingConfiguration.isSupported,
              let frame = session.currentFrame,
              case .normal = frame.camera.trackingState,
              ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.25 else {
            message = "相機追蹤尚未就緒，請稍微移動手機後再試。"
            return
        }
        let score = WaterCaptureGeometry.alignmentScore(
            cameraZWorldY: Double(frame.camera.transform.columns.2.y)
        )
        guard score >= 0.82 else {
            message = "請將手機鏡頭垂直向下，保持在瓶口正上方。"
            return
        }
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
            return
        }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
            message = "無法取得影像，請重試。"
            return
        }
        onCapture(CalibratedWaterCapture(
            image: UIImage(cgImage: cgImage, scale: 1, orientation: .up),
            focalLengthPixels: focal,
            alignmentScore: score,
            capturedAt: Date(),
            frameTimestamp: frame.timestamp
        ))
        dismiss()
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
