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
    var serverStatus: ServerStatus = .unknown

    enum ServerStatus: Equatable {
        case unknown
        case checking
        case online
        case offline(String)

        var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking…"
            case .online: return "Online"
            case .offline(let message): return "Offline: \(message)"
            }
        }
    }

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

    /// Lightweight preflight used by Settings and onboarding support. It
    /// avoids sending a large photo when the local FastAPI service is stopped
    /// or the phone is on another network.
    func checkServer() async {
        serverStatus = .checking
        let candidates = serverBaseURL == Self.macBonjourBaseURL
            ? [serverBaseURL]
            : [serverBaseURL, Self.macBonjourBaseURL]

        var lastMessage = "No response"
        for baseURL in candidates {
            guard let url = URL(string: "\(baseURL)/health") else {
                lastMessage = "Invalid server URL"
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 4

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastMessage = "Invalid response"
                    continue
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    lastMessage = "HTTP \(httpResponse.statusCode)"
                    continue
                }

                if baseURL != serverBaseURL {
                    serverBaseURL = baseURL
                }
                serverStatus = .online
                return
            } catch {
                lastMessage = error.localizedDescription
            }
        }

        serverStatus = .offline(lastMessage)
    }

    struct WaterVolumeResponse: Codable {
        struct AcousticResponse: Codable {
            let echo_snr_db: Double?
            let resonance_snr_db: Double?
            let resonance_frequency_hz: Double?
            let accepted_repeats: Int?
        }

        struct ReconciledProfileResponse: Codable {
            let heights_cm: [Double]
            let radii_cm: [Double]
        }

        let status: String
        let message: String
        let remaining_volume_ml: Double?
        let consumed_volume_ml: Double?
        let water_depth_cm: Double?
        let water_height_cm: Double?
        let confidence: Double?
        let method_used: String?
        let image_width: Int?
        let image_height: Int?
        let outer_center_x: Double?
        let outer_center_y: Double?
        let outer_radius_px: Double?
        let inner_center_x: Double?
        let inner_center_y: Double?
        let inner_radius_px: Double?
        let phone_to_rim_cm: Double?
        let requires_retake: Bool?
        let focus_stack_count: Int?
        let selected_focus_index: Int?
        let selected_focal_length_px: Double?
        let selected_lens_position: Double?
        let sharpness_gain: Double?
        let water_candidates: [WaterSurfaceCandidate]?
        let recommended_candidate_index: Int?
        let review_image_base64: String?
        let reconciled_profile: ReconciledProfileResponse?
        let acoustic_estimate: AcousticResponse?
        let debug_image_base64: String?
    }

    private struct FocusFrameMetadataItem: Encodable {
        let rim: [Double]
        let focal_length_px: Double
        let lens_position: Float
    }

    private struct FocusStackMetadataPayload: Encodable {
        let base_lens_position: Float?
        let frames: [FocusFrameMetadataItem]
    }

    private struct ManualCirclePayload: Encodable {
        let outer_center_x: Double
        let outer_center_y: Double
        let outer_radius_px: Double
        let inner_center_x: Double
        let inner_center_y: Double
        let inner_radius_px: Double
    }

    /// Uploads the locked-rim frame plus any interior focus-bracketed frames,
    /// returning the clean all-in-focus image and ranked water candidates for
    /// immediate user verification or adjustment.
    func scanWaterVolumeForReview(
        capture: CalibratedWaterCapture,
        bottle: BottleProfile,
        lastRemainingML: Double? = nil,
        secondsSinceLastScan: Double? = nil
    ) async throws -> WaterScanReview {
        guard let baseJPEG = capture.image.jpegData(compressionQuality: 0.85) else {
            throw APIError.serverError("影像編碼失敗，請重新對齊。")
        }

        isLoading = true
        lastError = nil
        lastDebugImage = nil
        defer { isLoading = false }

        let boundary = UUID().uuidString
        var body = Data()
        appendFileField(&body, boundary: boundary, name: "image", filename: "capture.jpg", mime: "image/jpeg", data: baseJPEG)

        var focusMetaItems: [FocusFrameMetadataItem] = []
        for (idx, frame) in capture.focusFrames.enumerated() {
            guard let frameJPEG = frame.image.jpegData(compressionQuality: 0.80) else { continue }
            appendFileField(
                &body,
                boundary: boundary,
                name: "focus_frames",
                filename: "focus_\(idx).jpg",
                mime: "image/jpeg",
                data: frameJPEG
            )
            focusMetaItems.append(
                FocusFrameMetadataItem(
                    rim: frame.rim,
                    focal_length_px: frame.focalLengthPixels,
                    lens_position: frame.lensPosition
                )
            )
        }
        if !focusMetaItems.isEmpty {
            let metaPayload = FocusStackMetadataPayload(
                base_lens_position: capture.rimLensPosition,
                frames: focusMetaItems
            )
            let metaData = try JSONEncoder().encode(metaPayload)
            appendFormField(
                &body,
                boundary: boundary,
                name: "focus_metadata_json",
                value: String(decoding: metaData, as: UTF8.self)
            )
        }

        let rimJSON = try JSONEncoder().encode(capture.rim)
        appendFormField(&body, boundary: boundary, name: "guided_rim_json", value: String(decoding: rimJSON, as: UTF8.self))
        appendFormField(&body, boundary: boundary, name: "return_candidates", value: "true")
        appendFormField(&body, boundary: boundary, name: "bottle_height_cm", value: "\(bottle.heightCM)")
        appendFormField(&body, boundary: boundary, name: "bottle_volume_ml", value: "\(bottle.totalVolumeMl)")
        appendFormField(&body, boundary: boundary, name: "opening_diameter_cm", value: "\(bottle.diameterCM)")
        appendFormField(&body, boundary: boundary, name: "profile_json", value: try buildProfileJSON(bottle: bottle))
        appendFormField(&body, boundary: boundary, name: "calibration_outer_radius_px", value: "\(bottle.calibrationOuterRadiusPx)")
        appendFormField(&body, boundary: boundary, name: "imu_alignment_score", value: "\(capture.alignmentScore)")
        appendFormField(&body, boundary: boundary, name: "surface_mode", value: "auto")
        appendFormField(&body, boundary: boundary, name: "acoustic_metadata_json", value: "{}")
        let safeLastRemainingML: Double? = lastRemainingML.flatMap { value in
            guard value.isFinite, (0...bottle.totalVolumeMl).contains(value) else { return nil }
            return value
        }
        appendOptionalFormField(&body, boundary: boundary, name: "last_remaining_ml", value: safeLastRemainingML.map { String($0) })
        appendOptionalFormField(&body, boundary: boundary, name: "seconds_since_last_scan", value: secondsSinceLastScan.map { String($0) })
        appendOptionalFormField(&body, boundary: boundary, name: "camera_focal_length_px", value: String(capture.focalLengthPixels))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (httpResponse, decoded) = try await postEstimate(body: body, boundary: boundary, timeout: 18)

        if httpResponse.statusCode == 200, decoded.status == "retake" {
            throw APIError.retake(decoded.message)
        }

        guard httpResponse.statusCode == 200,
              decoded.status == "ok" || decoded.status == "review",
              let outerX = decoded.outer_center_x ?? capture.rim.first,
              let outerY = decoded.outer_center_y ?? (capture.rim.count > 1 ? capture.rim[1] : nil),
              let outerR = decoded.outer_radius_px ?? (capture.rim.count > 2 ? capture.rim[2] : nil),
              let phoneToRim = decoded.phone_to_rim_cm else {
            lastError = decoded.message
            throw APIError.serverError(decoded.message)
        }

        let cleanReviewImage: UIImage
        if let b64 = decoded.review_image_base64,
           let imgData = Data(base64Encoded: b64),
           let img = UIImage(data: imgData) {
            cleanReviewImage = img
        } else {
            cleanReviewImage = capture.image
        }

        let rawW = decoded.image_width ?? capture.image.cgImage?.width ?? Int(capture.image.size.width)
        let rawH = decoded.image_height ?? capture.image.cgImage?.height ?? Int(capture.image.size.height)

        let autoResult: WaterScanResult?
        if decoded.status == "ok",
           let remaining = decoded.remaining_volume_ml,
           remaining.isFinite,
           (0...bottle.totalVolumeMl).contains(remaining) {
            autoResult = WaterScanResult(
                remainingML: remaining,
                consumedML: decoded.consumed_volume_ml,
                waterDepthCM: decoded.water_depth_cm,
                waterHeightCM: decoded.water_height_cm,
                confidence: decoded.confidence ?? 0,
                methodUsed: decoded.method_used ?? "vision_perspective_profile",
                outerRadiusPx: outerR,
                debugImageBase64: decoded.debug_image_base64,
                message: decoded.message,
                echoSNRDB: decoded.acoustic_estimate?.echo_snr_db,
                resonanceSNRDB: decoded.acoustic_estimate?.resonance_snr_db,
                resonanceFrequencyHz: decoded.acoustic_estimate?.resonance_frequency_hz,
                acceptedAcousticRepeats: decoded.acoustic_estimate?.accepted_repeats
            )
        } else {
            autoResult = nil
        }

        let recHeights = decoded.reconciled_profile?.heights_cm ?? bottle.profileHeightCM
        let recRadii = decoded.reconciled_profile?.radii_cm ?? bottle.profileRadiusCM
        let fallbackHeights = recHeights.count >= 2 ? recHeights : [0, bottle.heightCM]
        let fallbackRadii = recRadii.count == fallbackHeights.count ? recRadii : [bottle.diameterCM / 2, bottle.diameterCM / 2]

        return WaterScanReview(
            status: decoded.status,
            message: decoded.message,
            reviewImage: cleanReviewImage,
            rawImageWidth: rawW,
            rawImageHeight: rawH,
            outerCenterX: outerX,
            outerCenterY: outerY,
            outerRadiusPx: outerR,
            focalLengthPx: decoded.selected_focal_length_px ?? capture.focalLengthPixels,
            phoneToRimCM: phoneToRim,
            imuAlignmentScore: capture.alignmentScore,
            reconciledHeightsCM: fallbackHeights,
            reconciledRadiiCM: fallbackRadii,
            candidates: decoded.water_candidates ?? [],
            recommendedCandidateIndex: decoded.recommended_candidate_index,
            autoResult: autoResult,
            focusStackCount: decoded.focus_stack_count ?? 1,
            selectedFocusIndex: decoded.selected_focus_index ?? 0,
            selectedLensPosition: decoded.selected_lens_position,
            sharpnessGain: decoded.sharpness_gain,
            lastRemainingBaselineML: safeLastRemainingML,
            previousScanAgeSeconds: secondsSinceLastScan
        )
    }

    /// Confirms a user-adjusted water circle against the locked bottle rim on the backend.
    func confirmManualWaterCircle(
        image: UIImage,
        bottle: BottleProfile,
        outerCenter: CGPoint,
        outerRadiusPx: Double,
        innerCenter: CGPoint,
        innerRadiusPx: Double,
        focalLengthPx: Double,
        imuAlignmentScore: Double,
        lastRemainingML: Double? = nil,
        secondsSinceLastScan: Double? = nil
    ) async throws -> WaterScanResult {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw APIError.serverError("影像編碼失敗，請重試。")
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let boundary = UUID().uuidString
        var body = Data()
        appendFileField(&body, boundary: boundary, name: "image", filename: "review.jpg", mime: "image/jpeg", data: jpeg)

        let manualPayload = ManualCirclePayload(
            outer_center_x: Double(outerCenter.x),
            outer_center_y: Double(outerCenter.y),
            outer_radius_px: outerRadiusPx,
            inner_center_x: Double(innerCenter.x),
            inner_center_y: Double(innerCenter.y),
            inner_radius_px: innerRadiusPx
        )
        let manualData = try JSONEncoder().encode(manualPayload)
        appendFormField(&body, boundary: boundary, name: "manual_circles_json", value: String(decoding: manualData, as: UTF8.self))
        appendFormField(&body, boundary: boundary, name: "reconcile_lip", value: "true")
        appendFormField(&body, boundary: boundary, name: "allow_large_change", value: "true")
        appendFormField(&body, boundary: boundary, name: "bottle_height_cm", value: "\(bottle.heightCM)")
        appendFormField(&body, boundary: boundary, name: "bottle_volume_ml", value: "\(bottle.totalVolumeMl)")
        appendFormField(&body, boundary: boundary, name: "opening_diameter_cm", value: "\(bottle.diameterCM)")
        appendFormField(&body, boundary: boundary, name: "profile_json", value: try buildProfileJSON(bottle: bottle))
        appendFormField(&body, boundary: boundary, name: "calibration_outer_radius_px", value: "\(bottle.calibrationOuterRadiusPx)")
        appendFormField(&body, boundary: boundary, name: "imu_alignment_score", value: "\(imuAlignmentScore)")
        appendFormField(&body, boundary: boundary, name: "surface_mode", value: "auto")
        appendFormField(&body, boundary: boundary, name: "acoustic_metadata_json", value: "{}")
        let safeLastRemainingML: Double? = lastRemainingML.flatMap { value in
            guard value.isFinite, (0...bottle.totalVolumeMl).contains(value) else { return nil }
            return value
        }
        appendOptionalFormField(&body, boundary: boundary, name: "last_remaining_ml", value: safeLastRemainingML.map { String($0) })
        appendOptionalFormField(&body, boundary: boundary, name: "seconds_since_last_scan", value: secondsSinceLastScan.map { String($0) })
        appendOptionalFormField(&body, boundary: boundary, name: "camera_focal_length_px", value: String(focalLengthPx))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (httpResponse, decoded) = try await postEstimate(body: body, boundary: boundary, timeout: 12)
        if httpResponse.statusCode == 200, decoded.status == "retake" {
            throw APIError.retake(decoded.message)
        }
        guard httpResponse.statusCode == 200,
              decoded.status == "ok",
              decoded.requires_retake != true,
              let remaining = decoded.remaining_volume_ml,
              remaining.isFinite,
              (0...bottle.totalVolumeMl).contains(remaining) else {
            lastError = decoded.message
            throw APIError.serverError(decoded.message)
        }

        return WaterScanResult(
            remainingML: remaining,
            consumedML: decoded.consumed_volume_ml,
            waterDepthCM: decoded.water_depth_cm,
            waterHeightCM: decoded.water_height_cm,
            confidence: decoded.confidence ?? 0.9,
            methodUsed: decoded.method_used ?? "vision_manual_circles_profile",
            outerRadiusPx: decoded.outer_radius_px ?? outerRadiusPx,
            debugImageBase64: decoded.debug_image_base64,
            message: decoded.message,
            echoSNRDB: nil,
            resonanceSNRDB: nil,
            resonanceFrequencyHz: nil,
            acceptedAcousticRepeats: nil
        )
    }

    private func postEstimate(
        body: Data,
        boundary: String,
        timeout: TimeInterval
    ) async throws -> (HTTPURLResponse, WaterVolumeResponse) {
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
            request.timeoutInterval = timeout
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
        return (httpResponse, decoded)
    }

    func scanWaterVolume(
        imageData: Data,
        bottle: BottleProfile,
        imuAlignmentScore: Double = 1.0,
        lastRemainingML: Double? = nil,
        secondsSinceLastScan: Double? = nil,
        audioData: Data? = nil,
        acousticMetadataJSON: String = "{}",
        cameraFocalLengthPx: Double? = nil,
        phoneToRimCM: Double? = nil,
        surfaceMode: String = "auto",
        guidedRim: [Double]? = nil
    ) async throws -> WaterScanResult {
        isLoading = true
        lastError = nil
        lastDebugImage = nil
        defer { isLoading = false }

        let boundary = UUID().uuidString
        var body = Data()
        appendFileField(&body, boundary: boundary, name: "image", filename: "capture.jpg", mime: "image/jpeg", data: imageData)
        if let guidedRim {
            let json = try JSONEncoder().encode(guidedRim)
            appendFormField(&body, boundary: boundary, name: "guided_rim_json", value: String(decoding: json, as: UTF8.self))
        }
        if let audioData {
            appendFileField(&body, boundary: boundary, name: "audio", filename: "capture.wav", mime: "audio/wav", data: audioData)
        }
        appendFormField(&body, boundary: boundary, name: "bottle_height_cm", value: "\(bottle.heightCM)")
        appendFormField(&body, boundary: boundary, name: "bottle_volume_ml", value: "\(bottle.totalVolumeMl)")
        appendFormField(&body, boundary: boundary, name: "opening_diameter_cm", value: "\(bottle.diameterCM)")
        appendFormField(&body, boundary: boundary, name: "profile_json", value: try buildProfileJSON(bottle: bottle))
        appendFormField(&body, boundary: boundary, name: "calibration_outer_radius_px", value: "\(bottle.calibrationOuterRadiusPx)")
        appendFormField(&body, boundary: boundary, name: "imu_alignment_score", value: "\(imuAlignmentScore)")
        appendFormField(&body, boundary: boundary, name: "surface_mode", value: surfaceMode)
        appendFormField(&body, boundary: boundary, name: "acoustic_metadata_json", value: acousticMetadataJSON)
        // Treat a baseline from another bottle (or a corrupt persisted value)
        // as absent. This keeps a valid image scan from failing validation
        // before the server gets a chance to analyse it.
        let safeLastRemainingML: Double? = lastRemainingML.flatMap { (value: Double) -> Double? in
            guard value.isFinite, (0...bottle.totalVolumeMl).contains(value) else { return nil }
            return value
        }
        appendOptionalFormField(&body, boundary: boundary, name: "last_remaining_ml", value: safeLastRemainingML.map { String($0) })
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

        if httpResponse.statusCode == 200, decoded.status == "retake" {
            throw APIError.retake(decoded.message)
        }

        guard httpResponse.statusCode == 200,
              decoded.status == "ok",
              decoded.requires_retake != true,
              let remaining = decoded.remaining_volume_ml,
              remaining.isFinite,
              (0...bottle.totalVolumeMl).contains(remaining) else {
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

    /// An absent profile is an explicit cylinder assumption; a damaged profile
    /// must not silently become that assumption.
    func buildProfileJSON(bottle: BottleProfile) throws -> String {
        let heights = bottle.profileHeightCM
        let radii = bottle.profileRadiusCM
        if heights.isEmpty && radii.isEmpty { return "{}" }
        guard heights.count >= 2, heights.count == radii.count,
              heights.allSatisfy({ $0.isFinite && $0 >= 0 }),
              radii.allSatisfy({ $0.isFinite && $0 > 0 }),
              heights.first == 0,
              bottle.heightCM.isFinite,
              abs((heights.last ?? 0) - bottle.heightCM) < 0.001,
              zip(heights, heights.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw APIError.invalidBottleProfile
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "heights_cm": heights, "radii_cm": radii
        ])
        guard let string = String(data: data, encoding: .utf8) else {
            throw APIError.invalidBottleProfile
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
        case invalidBottleProfile
        case connectionFailed(String)
        case retake(String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL. Check your Mac IP in Settings."
            case .invalidBottleProfile:
                return "瓶子輪廓資料不完整，請重新建立模型後再量測。"
            case .invalidResponse:
                return "No response from server."
            case .connectionFailed(let message):
                return "Cannot reach the measurement server. Check that the Mac backend is running and both devices are on the same network. (\(message))"
            case .serverError(let message), .retake(let message):
                return message
            }
        }
    }
}
