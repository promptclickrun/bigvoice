import AVFoundation
import AudioToolbox
import BigvoiceCore
import Foundation
import OSLog

struct RecordingSnapshot {
    let level: Float
    let duration: TimeInterval
    let reachedLimit: Bool
}

private final class RecordingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var level: Float = 0
    private var accepting = true
    private var reportedError = false

    func append(_ values: [Float]) {
        let clean = values.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        let rms = AudioAnalysis.rms(clean)
        lock.withLock {
            guard accepting else { return }
            let remaining = AudioAnalysis.maximumSamples - samples.count
            samples.append(contentsOf: clean.prefix(max(0, remaining)))
            level = AudioAnalysis.meter(rms: rms)
        }
    }

    func snapshot() -> RecordingSnapshot {
        lock.withLock {
            RecordingSnapshot(level: level, duration: Double(samples.count) / 16_000,
                              reachedLimit: samples.count >= AudioAnalysis.maximumSamples)
        }
    }

    /// Samples captured since `index`, for incremental live transcription.
    func copy(from index: Int) -> [Float] {
        lock.withLock { index < samples.count ? Array(samples[max(0, index)...]) : [] }
    }

    var count: Int { lock.withLock { samples.count } }

    func take() -> [Float] {
        lock.withLock {
            accepting = false
            let result = samples
            samples = []
            return result
        }
    }

    func claimError() -> Bool {
        lock.withLock {
            guard !reportedError, accepting else { return false }
            reportedError = true
            return true
        }
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied, invalidFormat, conversion, missingAudioUnit
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access is off. Enable bigvoice in System Settings > Privacy & Security > Microphone."
        case .invalidFormat: return "This microphone has no usable audio stream. Choose another input device."
        case .conversion: return "The microphone's audio could not be converted. Try reconnecting it or selecting another input."
        case .missingAudioUnit: return "macOS could not open this audio input."
        }
    }
}

@MainActor
final class AudioCapture {
    private var engine: AVAudioEngine?
    private var buffer: RecordingBuffer?
    private var configurationObserver: NSObjectProtocol?
    private var generation = UUID()
    var onInterrupted: ((String) -> Void)?

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(deviceID: AudioDeviceID) throws {
        _ = stop()
        let generation = UUID()
        self.generation = generation
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else { throw CaptureError.missingAudioUnit }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioDeviceError(message: "The selected microphone could not be opened", status: status)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat) else { throw CaptureError.invalidFormat }
        let buffer = RecordingBuffer()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] pcm, _ in
            let capacity = AVAudioFrameCount(ceil(Double(pcm.frameLength) * 16_000 / format.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                if buffer.claimError() {
                    Task { @MainActor in
                        guard self?.generation == generation else { return }
                        self?.onInterrupted?(CaptureError.conversion.localizedDescription)
                    }
                }
                return
            }
            var provided = false
            var error: NSError?
            let result = converter.convert(to: converted, error: &error) { _, inputStatus in
                if provided { inputStatus.pointee = .noDataNow; return nil }
                provided = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if result == .error || error != nil {
                if buffer.claimError() {
                    Logger.audio.error("Microphone conversion failed")
                    Task { @MainActor in
                        guard self?.generation == generation else { return }
                        self?.onInterrupted?(CaptureError.conversion.localizedDescription)
                    }
                }
                return
            }
            if let channel = converted.floatChannelData?[0] {
                buffer.append(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
            }
        }
        engine.prepare()
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); throw error }
        self.engine = engine
        self.buffer = buffer
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.engine != nil, self?.generation == generation else { return }
                self?.onInterrupted?("The audio device changed. Your captured audio will be transcribed.")
            }
        }
    }

    func snapshot() -> RecordingSnapshot {
        buffer?.snapshot() ?? RecordingSnapshot(level: 0, duration: 0, reachedLimit: false)
    }

    func samples(from index: Int) -> [Float] { buffer?.copy(from: index) ?? [] }
    var sampleCount: Int { buffer?.count ?? 0 }

    @discardableResult
    func stop() -> [Float] {
        generation = UUID()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        let samples = buffer?.take() ?? []
        buffer = nil
        return samples
    }
}
