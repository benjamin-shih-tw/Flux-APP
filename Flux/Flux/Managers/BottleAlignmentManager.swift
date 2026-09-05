import Foundation
import CoreMotion
import Observation

@Observable
final class BottleAlignmentManager {
    private let motionManager = CMMotionManager()

    var isMonitoring = false
    var pitchDegrees: Double = 0
    var rollDegrees: Double = 0
    var accelerationMagnitude: Double = 0
    var rotationRateMagnitude: Double = 0
    var alignmentScore: Double = 0
    var guidanceMessage: String = "Lift the phone above the bottle opening."

    var captureReady: Bool {
        alignmentScore >= 0.82
    }

    var statusLabel: String {
        if !motionManager.isDeviceMotionAvailable {
            return "IMU unavailable on this device"
        }
        if captureReady {
            return "Aligned and steady"
        }
        return "Adjust the phone before capturing"
    }

    var statusDetail: String {
        if !motionManager.isDeviceMotionAvailable {
            return "Core Motion is not available here."
        }

        return String(
            format: "Pitch %.0f°  Roll %.0f°  Stability %.0f%%",
            pitchDegrees,
            rollDegrees,
            alignmentScore * 100.0
        )
    }

    func startMonitoring() {
        guard motionManager.isDeviceMotionAvailable else {
            guidanceMessage = "Core Motion is not available on this device."
            alignmentScore = 0
            isMonitoring = false
            return
        }

        if motionManager.isDeviceMotionActive {
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.isMonitoring = true
            self.update(with: motion)
        }
    }

    func stopMonitoring() {
        motionManager.stopDeviceMotionUpdates()
        isMonitoring = false
    }

    private func update(with motion: CMDeviceMotion) {
        pitchDegrees = motion.attitude.pitch * 180.0 / .pi
        rollDegrees = motion.attitude.roll * 180.0 / .pi

        let ax = motion.userAcceleration.x
        let ay = motion.userAcceleration.y
        let az = motion.userAcceleration.z
        let rx = motion.rotationRate.x
        let ry = motion.rotationRate.y
        let rz = motion.rotationRate.z

        accelerationMagnitude = sqrt(ax * ax + ay * ay + az * az)
        rotationRateMagnitude = sqrt(rx * rx + ry * ry + rz * rz)

        let pitchScore = max(0, 1 - abs(pitchDegrees) / 14)
        let rollScore = max(0, 1 - abs(rollDegrees) / 14)
        let motionScore = max(0, 1 - accelerationMagnitude / 0.25)
        let rotationScore = max(0, 1 - rotationRateMagnitude / 0.9)

        alignmentScore = max(
            0,
            min(
                1,
                pitchScore * 0.34
                    + rollScore * 0.34
                    + motionScore * 0.16
                    + rotationScore * 0.16
            )
        )

        if captureReady {
            guidanceMessage = "Aligned. Hold steady and capture."
        } else if abs(pitchDegrees) > 14 || abs(rollDegrees) > 14 {
            guidanceMessage = "Level the phone over the bottle opening."
        } else if accelerationMagnitude > 0.18 || rotationRateMagnitude > 0.7 {
            guidanceMessage = "Hold still for a moment."
        } else {
            guidanceMessage = "Fine tune the frame until the rim is centred."
        }
    }
}
