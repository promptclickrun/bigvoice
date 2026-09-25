import BigvoiceCore
import Foundation

public actor NativeTranscriber {
    private let whisper: WhisperTranscriber
    private var closed = false

    public init(useGPU: Bool = true) {
        whisper = WhisperTranscriber(useGPU: useGPU)
    }

    public func prepare(model: LocalModel) async throws {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        switch model.kind {
        case .whisper:
            await ONNXTranscriber.shared.unload()
            try await whisper.prepare(model: model)
        case .nemotronONNX:
            await whisper.unload()
            try await ONNXTranscriber.shared.prepare(model: model)
        }
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
    }

    public func transcribe(samples: [Float], model: LocalModel, language: String = "auto") async throws -> String {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        guard samples.count <= AudioAnalysis.maximumSamples, samples.allSatisfy(\.isFinite) else {
            throw ONNXInferenceError.invalidAudio
        }
        guard AudioAnalysis.hasAudibleContent(samples) else { throw TranscriptionError.noSpeech }
        try Self.validate(language: language, for: model)
        try await prepare(model: model)
        switch model.kind {
        case .whisper:
            return try await whisper.transcribe(samples: samples, model: model, language: language)
        case .nemotronONNX:
            return try await ONNXTranscriber.shared.transcribe(samples: samples, model: model, language: language)
        }
    }

    /// Rejects languages a model cannot produce before any weights are loaded.
    public static func validate(language: String, for model: LocalModel) throws {
        let englishOnly: Bool
        switch model.kind {
        case .nemotronONNX: englishOnly = true
        case let .whisper(_, multilingual): englishOnly = !multilingual
        }
        if englishOnly && !["auto", "en"].contains(language) {
            throw TranscriptionError.unsupportedLanguage(language)
        }
    }

    public func unload() async {
        await whisper.unload()
        await ONNXTranscriber.shared.unload()
    }

    // MARK: Live streaming (ONNX speech models)

    public static func supportsStreaming(_ model: LocalModel) -> Bool {
        if case .nemotronONNX = model.kind { return true }
        return false
    }

    public func beginStream(model: LocalModel) async throws {
        guard !closed, Self.supportsStreaming(model) else { throw CancellationError() }
        await whisper.unload()
        try await ONNXTranscriber.shared.beginStream(model: model)
    }

    public func feedStream(_ samples: [Float]) async throws -> String {
        guard !closed else { throw CancellationError() }
        return try await ONNXTranscriber.shared.feedStream(samples)
    }

    public func finishStream(_ remaining: [Float]) async throws -> String {
        guard !closed else { throw CancellationError() }
        guard remaining.allSatisfy(\.isFinite) else { throw ONNXInferenceError.invalidAudio }
        return try await ONNXTranscriber.shared.finishStream(remaining)
    }

    public func cancelStream() async {
        await ONNXTranscriber.shared.closeStream()
    }

    public func shutdown() async {
        closed = true
        await unload()
    }
}
