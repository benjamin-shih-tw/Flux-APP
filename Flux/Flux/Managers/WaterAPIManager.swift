import Foundation
import UIKit

/// Manages communication with the Python FastAPI water volume backend.
/// Run: cd quick-oppenheimer && uvicorn main:app --host 0.0.0.0 --port 8000
@Observable
final class WaterAPIManager {

    var serverBaseURL: String = "http://10.0.0.9:8000"
    var isLoading: Bool = false
    var lastError: String? = nil
    var lastDebugImage: UIImage? = nil

    struct WaterVolumeResponse: Codable {
        let status: String
        let message: String
        let remaining_volume_ml: Double?
        let consumed_volume_ml: Double?
        let water_height_cm: Double?
        let outer_radius_px: Double?
        let debug_image_base64: String?
    }

    /// Scan a top-down photo using calibrated bottle profile + optional last-scan baseline.
    func scanWaterVolume(
        imageData: Data,
        bottle: BottleProfile,
        lastRemainingML: Double = 0
    ) async throws -> WaterScanResult {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        guard let url = URL(string: "\(serverBaseURL)/api/v1/calculate_water_volume") else {
            throw APIError.invalidURL
        }

        let profileJSON = buildProfileJSON(bottle: bottle)
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        var body = Data()
        appendFileField(&body, boundary: boundary, name: "image", filename: "capture.jpg", mime: "image/jpeg", data: imageData)
        appendFormField(&body, boundary: boundary, name: "bottle_height", value: "\(bottle.heightCM)")
        appendFormField(&body, boundary: boundary, name: "bottle_volume", value: "\(bottle.totalVolumeMl)")
        appendFormField(&body, boundary: boundary, name: "opening_diameter_cm", value: "\(bottle.diameterCM)")
        appendFormField(&body, boundary: boundary, name: "profile_json", value: profileJSON)
        appendFormField(&body, boundary: boundary, name: "last_remaining_ml", value: "\(lastRemainingML)")
        appendFormField(&body, boundary: boundary, name: "calibration_outer_radius_px", value: "\(bottle.calibrationOuterRadiusPx)")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(WaterVolumeResponse.self, from: data)

        if let b64 = decoded.debug_image_base64,
           let imgData = Data(base64Encoded: b64),
           let img = UIImage(data: imgData) {
            await MainActor.run { self.lastDebugImage = img }
        }

        guard httpResponse.statusCode == 200,
              decoded.status == "ok",
              let remaining = decoded.remaining_volume_ml else {
            let msg = decoded.message
            lastError = msg
            throw APIError.serverError(msg)
        }

        return WaterScanResult(
            remainingML: remaining,
            consumedML: decoded.consumed_volume_ml,
            waterHeightCM: decoded.water_height_cm,
            outerRadiusPx: decoded.outer_radius_px,
            debugImageBase64: decoded.debug_image_base64,
            message: decoded.message
        )
    }

    /// Legacy wrapper — prefer scanWaterVolume(imageData:bottle:lastRemainingML:).
    func calculateWaterVolume(
        imageData: Data,
        bottleHeightCM: Double,
        bottleVolumeMl: Double,
        cameraDistanceCM: Double = 15.0
    ) async throws -> Double {
        let stub = BottleProfile(totalVolumeMl: bottleVolumeMl, heightCM: bottleHeightCM, diameterCM: 7)
        let result = try await scanWaterVolume(imageData: imageData, bottle: stub)
        return result.remainingML
    }

    // MARK: - Private

    private func buildProfileJSON(bottle: BottleProfile) -> String {
        guard bottle.hasCalibratedProfile else { return "{}" }
        let payload: [String: [Double]] = [
            "heights_cm": bottle.profileHeightCM,
            "radii_cm": bottle.profileRadiusCM
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private func appendFormField(_ body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
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
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid server URL. Check your Mac IP in Settings."
            case .invalidResponse: return "No response from server."
            case .serverError(let msg): return msg
            }
        }
    }
}
