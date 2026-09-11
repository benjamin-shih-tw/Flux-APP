import Foundation
import UIKit
import Observation

/// Sends the top-down image, IMU quality and optional phone acoustic capture
/// to the FastAPI volume estimator.
@Observable
final class WaterAPIManager {
    private static let macBonjourBaseURL = "http://lihongyideMacBook-Air.local:8000"
    private static let obsoleteServerURLs: Set<String> = [
        "http://10.166.88.142:8000",
        "http://192.168.50.200:8000"
    ]

    var serverBaseURL: String {
        didSet { UserDefaults.standard.set(serverBaseURL, forKey: "serverBaseURL") }
    }

    var isLoading = false
    var lastError: String?
    var lastDebugImage: UIImage?

    init() {
        let saved = UserDefaults.standard.string(forKey: "serverBaseURL")
        if let saved, !Self.obsoleteServerURLs.contains(saved) {
            serverBaseURL = saved
        } else {
            // A Bonjour hostname remains stable when DHCP assigns the Mac a
            // different numeric address on another Wi-Fi network.
            serverBaseURL = Self.macBonjourBaseURL
            UserDefaults.standard.set(serverBaseURL, forKey: "serverBaseURL")
        }
    }

    struct WaterVolumeResponse: Codable {
        struct AcousticResponse: Codable {
            let echo_snr_db: Double?
            let resonance_snr_db: Double?
            let resonance_frequency_hz: Double?
            let accepted_repeats: Int?
        }

        let status: String
        let message: String
        let remaining_volume_ml: Double?
        let consumed_volume_ml: Double?
        let water_depth_cm: Double?
        let water_height_cm: Double?
        let confidence: Double?
        let method_used: String?
        let outer_radius_px: Double?
        let inner_radius_px: Double?
        let phone_to_rim_cm: Double?
        let requires_retake: Bool?
        let acoustic_estimate: AcousticResponse?
        let debug_image_base64: String?
    }

    func scanWaterVolume(
        imageData: Data,
        bottle: BottleProfile,
        imuAlignmentScore: Double = 1.0,
        lastRemainingML: Double? = nil,
        secondsSinceLastScan: Double? = nil,
        audioData: Data? = nil,
        acousticMetadataJSON: String = "{}",
        cameraFocalLengthPx: Double? = 3_200,
        phoneToRimCM: Double? = nil,
        surfaceMode: String = "auto"
    ) async throws -> WaterScanResult {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let boundary = UUID().uuidString
        var body = Data()
        appendFileField(&body, boundary: boundary, name: "image", filename: "capture.jpg", mime: "image/jpeg", data: imageData)
        if let audioData {
            appendFileField(&body, boundary: boundary, name: "audio", filename: "capture.wav", mime: "audio/wav", data: audioData)
        }
        appendFormField(&body, boundary: boundary, name: "bottle_height_cm", value: "\(bottle.heightCM)")
        appendFormField(&body, boundary: boundary, name: "bottle_volume_ml", value: "\(bottle.totalVolumeMl)")
        appendFormField(&body, boundary: boundary, name: "opening_diameter_cm", value: "\(bottle.diameterCM)")
        appendFormField(&body, boundary: boundary, name: "profile_json", value: buildProfileJSON(bottle: bottle))
        appendFormField(&body, boundary: boundary, name: "calibration_outer_radius_px", value: "\(bottle.calibrationOuterRadiusPx)")
        appendFormField(&body, boundary: boundary, name: "imu_alignment_score", value: "\(imuAlignmentScore)")
        appendFormField(&body, boundary: boundary, name: "surface_mode", value: surfaceMode)
        appendFormField(&body, boundary: boundary, name: "acoustic_metadata_json", value: acousticMetadataJSON)
        appendOptionalFormField(&body, boundary: boundary, name: "last_remaining_ml", value: lastRemainingML.map { String($0) })
        appendOptionalFormField(&body, boundary: boundary, name: "seconds_since_last_scan", value: secondsSinceLastScan.map { String($0) })
        appendOptionalFormField(&body, boundary: boundary, name: "camera_focal_length_px", value: cameraFocalLengthPx.map { String($0) })
        appendOptionalFormField(&body, boundary: boundary, name: "phone_to_rim_cm", value: phoneToRimCM.map { String($0) })
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var baseURLs = [serverBaseURL]
        if serverBaseURL != Self.macBonjourBaseURL {
            baseURLs.append(Self.macBonjourBaseURL)
        }
        var responseData: Data?
        var urlResponse: URLResponse?
        var lastConnectionError: Error?

        for baseURL in baseURLs {
            guard let url = URL(string: "\(baseURL)/api/v2/estimate_water_volume") else {
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 12
            request.httpBody = body
            do {
                (responseData, urlResponse) = try await URLSession.shared.data(for: request)
                if baseURL != serverBaseURL {
                    serverBaseURL = baseURL
                }
                break
            } catch {
                lastConnectionError = error
            }
        }

        guard let data = responseData, let response = urlResponse else {
            throw APIError.connectionFailed(lastConnectionError?.localizedDescription ?? "Unknown network error")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(WaterVolumeResponse.self, from: data)
        if let base64 = decoded.debug_image_base64,
           let imageData = Data(base64Encoded: base64),
           let image = UIImage(data: imageData) {
            await MainActor.run { self.lastDebugImage = image }
        }

        guard httpResponse.statusCode == 200,
              decoded.status == "ok",
              let remaining = decoded.remaining_volume_ml else {
            lastError = decoded.message
            throw APIError.serverError(decoded.message)
        }

        return WaterScanResult(
            remainingML: remaining,
            consumedML: decoded.consumed_volume_ml,
            waterDepthCM: decoded.water_depth_cm,
            waterHeightCM: decoded.water_height_cm,
            confidence: decoded.confidence ?? 0,
            methodUsed: decoded.method_used ?? "unknown",
            outerRadiusPx: decoded.outer_radius_px,
            debugImageBase64: decoded.debug_image_base64,
            message: decoded.message,
            echoSNRDB: decoded.acoustic_estimate?.echo_snr_db,
            resonanceSNRDB: decoded.acoustic_estimate?.resonance_snr_db,
            resonanceFrequencyHz: decoded.acoustic_estimate?.resonance_frequency_hz,
            acceptedAcousticRepeats: decoded.acoustic_estimate?.accepted_repeats
        )
    }

    /// Compatibility wrapper for older call sites.
    func calculateWaterVolume(
        imageData: Data,
        bottleHeightCM: Double,
        bottleVolumeMl: Double,
        cameraDistanceCM: Double = 15.0
    ) async throws -> Double {
        let bottle = BottleProfile(totalVolumeMl: bottleVolumeMl, heightCM: bottleHeightCM, diameterCM: 7)
        let result = try await scanWaterVolume(
            imageData: imageData,
            bottle: bottle,
            audioData: nil,
            cameraFocalLengthPx: nil,
            phoneToRimCM: cameraDistanceCM
        )
        return result.remainingML
    }

    private func buildProfileJSON(bottle: BottleProfile) -> String {
        guard bottle.hasCalibratedProfile else { return "{}" }
        let payload: [String: [Double]] = [
            "heights_cm": bottle.profileHeightCM,
            "radii_cm": bottle.profileRadiusCM
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func appendFormField(_ body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendOptionalFormField(_ body: inout Data, boundary: String, name: String, value: String?) {
        guard let value else { return }
        appendFormField(&body, boundary: boundary, name: name, value: value)
    }

    private func appendFileField(_ body: inout Data, boundary: String, name: String, filename: String, mime: String, data: Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    enum APIError: LocalizedError {
        case invalidURL
        case invalidResponse
        case connectionFailed(String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL. Check your Mac IP in Settings."
            case .invalidResponse:
                return "No response from server."
            case .connectionFailed(let message):
                return "Cannot reach the measurement server. Check that the Mac backend is running and both devices are on the same network. (\(message))"
            case .serverError(let message):
                return message
            }
        }
    }
}
