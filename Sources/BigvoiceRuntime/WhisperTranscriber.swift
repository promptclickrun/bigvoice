import BigvoiceCore
import Foundation
import whisper

public enum TranscriptionError: LocalizedError {
    case couldNotLoad, failed(Int32), noSpeech, unsupportedLanguage(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotLoad:
            return "The speech model could not be loaded. Check that it is a complete Whisper GGML model and that enough memory is available."
        case let .failed(code):
            return "Local transcription failed (code \(code)). Try a shorter recording or a smaller model."
        case .noSpeech:
            return "No clear speech was detected. Check your input device and try speaking closer to the microphone."
        case let .unsupportedLanguage(language):
            return "This model cannot transcribe \(language). Choose a multilingual model or switch the language to English."
        }
    }
}

final class InferenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

actor WhisperTranscriber {
    private var context: OpaquePointer?
    private var loadedPath: String?
    private var loadedModification: Date?
    private var loadedSize: Int64?
    public let useGPU: Bool

    public init(useGPU: Bool = true) { self.useGPU = useGPU }

    deinit {
        if let context { whisper_free(context) }
    }

    public func prepare(model: LocalModel) throws {
        try Task.checkCancellation()
        guard case .whisper = model.kind else { throw TranscriptionError.couldNotLoad }
        let attributes = try FileManager.default.attributesOfItem(atPath: model.url.path)
        let modification = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.int64Value
        if loadedPath == model.url.path, loadedModification == modification, loadedSize == size, context != nil {
            return
        }
        _ = try ModelFileInspector.inspect(model.url, source: model.source, managedDirectory: ModelDiscovery.managedDirectory)
        unload()
        var parameters = whisper_context_default_params()
        #if arch(arm64)
        parameters.use_gpu = useGPU
        parameters.flash_attn = useGPU
        #else
        parameters.use_gpu = false
        parameters.flash_attn = false
        #endif
        guard let loaded = model.url.path.withCString({ whisper_init_from_file_with_params($0, parameters) }) else {
            throw TranscriptionError.couldNotLoad
        }
        context = loaded
        loadedPath = model.url.path
        loadedModification = modification
        loadedSize = size
        try Task.checkCancellation()
    }

    public func unload() {
        if let context { whisper_free(context) }
        context = nil
        loadedPath = nil
        loadedModification = nil
        loadedSize = nil
    }

    public func transcribe(samples: [Float], model: LocalModel, language: String = "auto") async throws -> String {
        let cancellation = InferenceCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard AudioAnalysis.hasAudibleContent(samples) else { throw TranscriptionError.noSpeech }
            try prepare(model: model)
            guard let context else { throw TranscriptionError.couldNotLoad }
            let selectedLanguage = !model.multilingual && language == "auto" ? "en" : language
            guard (model.multilingual || selectedLanguage == "en"),
                  selectedLanguage == "auto" || whisper_lang_id(selectedLanguage) >= 0 else {
                throw TranscriptionError.unsupportedLanguage(selectedLanguage)
            }
            var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            parameters.print_realtime = false
            parameters.print_progress = false
            parameters.print_timestamps = false
            parameters.print_special = false
            parameters.translate = false
            parameters.no_context = true
            parameters.no_timestamps = true
            parameters.suppress_blank = true
            parameters.suppress_nst = true
            parameters.single_segment = false
            parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
            parameters.abort_callback = { pointer in
                guard let pointer else { return false }
                return Unmanaged<InferenceCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
            }
            // Whisper requires at least one second, even for a quick push-to-talk utterance.
            var input = samples
            if input.count < AudioAnalysis.sampleRate {
                input.append(contentsOf: repeatElement(0, count: AudioAnalysis.sampleRate - input.count))
            }
            let result = selectedLanguage.withCString { languagePointer in
                parameters.language = languagePointer
                return input.withUnsafeBufferPointer { buffer in
                    whisper_full(context, parameters, buffer.baseAddress, Int32(buffer.count))
                }
            }
            try Task.checkCancellation()
            guard !cancellation.isCancelled else { throw CancellationError() }
            guard result == 0 else { throw TranscriptionError.failed(result) }
            var text = ""
            for index in 0..<whisper_full_n_segments(context) {
                if let segment = whisper_full_get_segment_text(context, index) {
                    text += String(cString: segment)
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.noSpeech }
            return text
        } onCancel: {
            cancellation.cancel()
        }
    }
}
