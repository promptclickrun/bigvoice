import Foundation

public enum DictationMode: String, Equatable, Sendable {
    case pushToTalk, handsFree, practice
}

public enum DictationPhase: Equatable, Sendable {
    case idle
    case arming(DictationMode)
    case recording(DictationMode)
    case transcribing
    case inserting

    public var isBusy: Bool { self != .idle }
    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

public struct CaptureLifecycle: Sendable {
    public private(set) var phase: DictationPhase = .idle
    public private(set) var stopRequested = false

    public init() {}

    @discardableResult
    public mutating func begin(_ mode: DictationMode) -> Bool {
        guard phase == .idle else { return false }
        stopRequested = false
        phase = .arming(mode)
        return true
    }

    @discardableResult
    public mutating func didArm() -> Bool {
        guard case let .arming(mode) = phase else { return false }
        guard !stopRequested else { reset(); return false }
        phase = .recording(mode)
        return true
    }

    @discardableResult
    public mutating func requestStop(pushToTalkRelease: Bool = false) -> Bool {
        switch phase {
        case let .arming(mode):
            guard !pushToTalkRelease || mode == .pushToTalk else { return false }
            stopRequested = true
            return false
        case let .recording(mode):
            guard !pushToTalkRelease || mode == .pushToTalk else { return false }
            phase = .transcribing
            return true
        default:
            return false
        }
    }

    public mutating func willInsert() {
        guard phase == .transcribing else { return }
        phase = .inserting
    }

    public mutating func reset() {
        phase = .idle
        stopRequested = false
    }
}

public enum AudioAnalysis {
    public static let sampleRate = 16_000
    public static let maximumDuration: TimeInterval = 600
    public static let maximumSamples = sampleRate * Int(maximumDuration)

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let power = samples.reduce(0.0) { sum, sample in
            let value = sample.isFinite ? Double(sample) : 0
            return sum + value * value
        }
        return Float(sqrt(power / Double(samples.count)))
    }

    public static func meter(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 55) / 45))
    }

    public static func hasAudibleContent(_ samples: [Float]) -> Bool {
        guard samples.count >= sampleRate / 4 else { return false }
        var audibleFrames = 0
        let frameSize = sampleRate / 50
        for start in stride(from: 0, to: samples.count, by: frameSize) {
            let frame = Array(samples[start..<min(samples.count, start + frameSize)])
            if rms(frame) > 0.004 { audibleFrames += frame.count }
        }
        return audibleFrames >= sampleRate / 5
    }
}

public enum DeliverySafety {
    public static func expectedValue(original: String?, selection: NSRange?, inserting text: String) -> String? {
        guard let original, let selection, selection.location != NSNotFound,
              selection.location >= 0, selection.length >= 0,
              selection.location <= (original as NSString).length,
              selection.length <= (original as NSString).length - selection.location else { return nil }
        return (original as NSString).replacingCharacters(in: selection, with: text)
    }

    public static func mayDeliver(originalPID: Int32, currentPID: Int32?,
                                  originalElementPresent: Bool, focusedElementMatches: Bool,
                                  secureInput: Bool) -> Bool {
        !secureInput && currentPID == originalPID &&
            (!originalElementPresent || focusedElementMatches)
    }

    public static func maySend(autoSend: Bool, insertionConfirmed: Bool,
                               focusStillMatches: Bool, cancelled: Bool) -> Bool {
        autoSend && insertionConfirmed && focusStillMatches && !cancelled
    }

    public static func shouldRestoreClipboard(ownedChangeCount: Int, currentChangeCount: Int) -> Bool {
        ownedChangeCount == currentChangeCount
    }
}
