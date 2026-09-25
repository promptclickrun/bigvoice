import AVFoundation
import BigvoiceCore
import Foundation

public enum AudioFileError: LocalizedError {
    case unsupported, conversionFailed, tooLong
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "The audio format cannot be converted to 16 kHz mono PCM."
        case .conversionFailed: return "Audio conversion failed."
        case .tooLong: return "The audio file exceeds the ten-minute recording limit."
        }
    }
}

public enum AudioFileReader {
    public static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration <= AudioAnalysis.maximumDuration else { throw AudioFileError.tooLong }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw AudioFileError.unsupported
        }
        var samples: [Float] = []
        var readError: Error?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input)
                    inputStatus.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream { break }
            if status == .error { throw AudioFileError.conversionFailed }
        }
        return samples
    }
}
