import AVFoundation
import Foundation

struct AcousticCapture {
    let wav: Data
    let sampleRate: Double
}

/// The audio callback must not touch main-actor state. Samples and continuity
/// checks are protected by one lock; no file or network I/O runs on that callback.
private final class ScanPCMBuffer: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var samples: [Float] = []
    nonisolated(unsafe) private var expectedTime: AVAudioFramePosition?
    nonisolated(unsafe) private var invalid = false

    nonisolated func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = buffer.floatChannelData?[0], time.isSampleTimeValid else {
            invalid = true
            return
        }
        if let expectedTime, time.sampleTime != expectedTime { invalid = true }
        expectedTime = time.sampleTime + AVAudioFramePosition(buffer.frameLength)
        guard samples.count + Int(buffer.frameLength) <= 144_000 else { invalid = true; return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    nonisolated func invalidate() {
        lock.lock()
        invalid = true
        lock.unlock()
    }

    nonisolated func finish() throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard !invalid else { throw AcousticCaptureManager.CaptureError.interrupted }
        return samples
    }
}

@MainActor
final class AcousticCaptureManager {
    enum CaptureError: LocalizedError {
        case permission, route, sampleRate, interrupted, volume
        var errorDescription: String? {
            switch self {
            case .permission: return "Enable microphone access in Settings to measure echoes."
            case .route: return "Disconnect headphones and use the iPhone speaker and bottom microphone."
            case .sampleRate: return "This audio route cannot capture the 15–20 kHz probe."
            case .interrupted: return "Audio capture was interrupted. Hold steady and retry."
            case .volume: return "Set the speaker volume between 20% and 60%, then retry."
            }
        }
    }

    func capture() async throws -> AcousticCapture {
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in continuation.resume(returning: granted) }
        }
        guard allowed else { throw CaptureError.permission }
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        let oldCategory = session.category
        let oldMode = session.mode
        let oldOptions = session.categoryOptions
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let store = ScanPCMBuffer()
        var tapInstalled = false
        var observers: [NSObjectProtocol] = []
        defer {
            player.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(oldCategory, mode: oldMode, options: oldOptions)
        }
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        guard let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
              let bottom = mic.dataSources?.first(where: { $0.orientation == .bottom }) else {
            throw CaptureError.route
        }
        try session.setPreferredInput(mic)
        try mic.setPreferredDataSource(bottom)
        try session.overrideOutputAudioPort(.speaker)
        guard session.currentRoute.inputs.allSatisfy({ $0.portType == .builtInMic }),
              session.currentRoute.outputs.allSatisfy({ $0.portType == .builtInSpeaker }),
              !session.currentRoute.inputs.isEmpty, !session.currentRoute.outputs.isEmpty else {
            throw CaptureError.route
        }
        guard (0.2...0.6).contains(session.outputVolume) else { throw CaptureError.volume }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let rate = format.sampleRate
        guard [44_100.0, 48_000.0].contains(rate), format.channelCount > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw CaptureError.sampleRate
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, .AVAudioEngineConfigurationChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                store.invalidate()
            })
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: mono)
        let probe = Self.makeProbe(rate: rate, format: mono)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            store.append(buffer, at: time)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        player.scheduleBuffer(probe)
        player.play()
        try await Task.sleep(for: .milliseconds(2100))
        guard engine.isRunning else { throw CaptureError.interrupted }
        player.stop()
        input.removeTap(onBus: 0)
        tapInstalled = false
        engine.stop()
        let samples = try store.finish()
        guard samples.count >= Int(rate*1.8) else { throw CaptureError.interrupted }
        return AcousticCapture(wav: Self.wav(samples, rate: Int(rate)), sampleRate: rate)
    }

    // Must agree with quick-oppenheimer/acoustics.py protocol v1.
    static func makeProbe(rate: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let length = Int(rate*1.9)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
        buffer.frameLength = AVAudioFrameCount(length)
        let channel = buffer.floatChannelData![0]
        channel.initialize(repeating: 0, count: length)
        func add(at start: Double, duration: Double, from f0: Double, to f1: Double, gain: Double) {
            let n = Int((rate*duration).rounded())
            let offset = Int((rate*start).rounded())
            for i in 0..<n {
                let t = Double(i)/rate
                let phase = 2*Double.pi*(f0*t+(f1-f0)*t*t/(2*duration))
                let window = 0.5-0.5*cos(2*Double.pi*Double(i)/Double(n-1))
                channel[offset+i] = Float(gain*sin(phase)*window)
            }
        }
        for start in [0.1, 0.3, 0.5, 0.7, 0.9] {
            add(at: start, duration: 0.001, from: 15_000, to: 20_000, gain: 0.35)
        }
        add(at: 1.2, duration: 0.3, from: 100, to: 3000, gain: 0.15)
        return buffer
    }

    static func wav(_ samples: [Float], rate: Int) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36+samples.count*2)); text("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate*2)); u16(2); u16(16)
        text("data"); u32(UInt32(samples.count*2))
        for sample in samples {
            let value = Int16((max(-1, min(1, sample))*32767).rounded())
            u16(UInt16(bitPattern: value))
        }
        return data
    }
}
