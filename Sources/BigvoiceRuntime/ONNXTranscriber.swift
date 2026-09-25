import BigvoiceCore
import Foundation

// GenAI's C API is not thread-safe. Every call, including teardown, shares this executor.
actor ONNXTranscriber {
    static let shared = ONNXTranscriber()
    private var library: ONNXLibrary?
    private var loaded: (config: OpaquePointer, model: OpaquePointer, path: String, settings: ONNXSpeechConfiguration)?
    private var stream: DecodeSession?

    private init() {}

    /// One decoding pipeline (streaming processor, tokenizer, token stream, generator) for one utterance.
    private final class DecodeSession {
        let api: ONNXLibrary
        let chunk: Int
        private var processor: OpaquePointer?
        private var tokenizer: OpaquePointer?
        private var tokenStream: OpaquePointer?
        private var parameters: OpaquePointer?
        private var generator: OpaquePointer?
        private(set) var transcript = ""

        init(api: ONNXLibrary, model: OpaquePointer, chunk: Int) throws {
            self.api = api
            self.chunk = chunk
            do {
                let processor = try api.create(api.createProcessor, from: model)
                self.processor = processor
                try api.check(api.setProcessorOption(processor, "use_vad", "false"))
                let tokenizer = try api.create(api.createTokenizer, from: model)
                self.tokenizer = tokenizer
                tokenStream = try api.create(api.createTokenizerStream, from: tokenizer)
                let parameters = try api.create(api.createParams, from: model)
                self.parameters = parameters
                var generator: OpaquePointer?
                try api.check(api.createGenerator(model, parameters, &generator))
                guard let generator else { throw ONNXInferenceError.runtime("The decoder could not be created.") }
                self.generator = generator
            } catch {
                close()
                throw error
            }
        }

        func feed(_ samples: [Float], cancelled: () throws -> Void) throws {
            guard let processor, !samples.isEmpty else { return }
            try samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    try cancelled()
                    let count = min(chunk, buffer.count - offset)
                    var inputs: OpaquePointer?
                    try api.check(api.processAudio(processor, base.advanced(by: offset), count, &inputs))
                    try decode(inputs, cancelled: cancelled)
                    offset += count
                }
            }
        }

        func flush(cancelled: () throws -> Void) throws {
            guard let processor else { return }
            try cancelled()
            var remaining: OpaquePointer?
            try api.check(api.flushAudio(processor, &remaining))
            try decode(remaining, cancelled: cancelled)
        }

        private func decode(_ inputs: OpaquePointer?, cancelled: () throws -> Void) throws {
            guard let inputs else { return }
            defer { api.destroyInputs(inputs) }
            guard let generator, let tokenStream else { return }
            try cancelled()
            try api.check(api.setInputs(generator, inputs))
            var steps = 0
            while !api.isDone(generator) {
                try cancelled()
                steps += 1
                guard steps <= 10_000, transcript.utf8.count < 200_000 else { throw ONNXInferenceError.decoderLimit }
                try api.check(api.generate(generator))
                var tokens: UnsafePointer<Int32>?
                var count = 0
                try api.check(api.getTokens(generator, &tokens, &count))
                guard (0...1).contains(count) else { throw ONNXInferenceError.runtime("Unexpected batched decoder output.") }
                if count == 1 {
                    guard let tokens else { throw ONNXInferenceError.runtime("The decoder returned no token data.") }
                    var text: UnsafePointer<CChar>?
                    try api.check(api.decodeToken(tokenStream, tokens[0], &text))
                    if let text { transcript += String(cString: text) }
                }
            }
        }

        func close() {
            if let generator { api.destroyGenerator(generator) }
            if let parameters { api.destroyParams(parameters) }
            if let tokenStream { api.destroyTokenizerStream(tokenStream) }
            if let tokenizer { api.destroyTokenizer(tokenizer) }
            if let processor { api.destroyProcessor(processor) }
            generator = nil; parameters = nil; tokenStream = nil; tokenizer = nil; processor = nil
        }
    }

    func prepare(model: LocalModel) throws {
        try Task.checkCancellation()
        let validated = try ONNXBundleInspector.inspect(model.url, source: model.source)
        guard case let .nemotronONNX(settings) = validated.kind else {
            throw ONNXInferenceError.runtime("This is not a supported ONNX speech model.")
        }
        if loaded?.path == validated.url.path, loaded?.settings.revision == settings.revision { return }
        unload()
        let api: ONNXLibrary
        if let library { api = library } else {
            api = try ONNXLibrary()
            library = api
        }
        try api.configurePrivacy()
        var config: OpaquePointer?
        var context: OpaquePointer?
        do {
            try api.check(validated.url.path.withCString { api.createConfig($0, &config) })
            guard let config else { throw ONNXInferenceError.runtime("The runtime returned no model configuration.") }
            context = try api.create(api.createModel, from: config)
            try Task.checkCancellation()
            guard let context else { throw ONNXInferenceError.runtime("The runtime returned no speech model.") }
            loaded = (config, context, validated.url.path, settings)
        } catch {
            if let context { api.destroyModel(context) }
            if let config { api.destroyConfig(config) }
            api.shutdown()
            throw error
        }
    }

    /// Streams must close before their model is destroyed and before the runtime shuts down.
    func unload() {
        closeStream()
        guard let loaded, let library else { return }
        self.loaded = nil
        library.destroyModel(loaded.model)
        library.destroyConfig(loaded.config)
        library.shutdown()
    }

    func transcribe(samples: [Float], model: LocalModel, language: String) async throws -> String {
        guard ["auto", "en"].contains(language) else { throw TranscriptionError.unsupportedLanguage(language) }
        let cancellation = InferenceCancellation()
        return try await withTaskCancellationHandler {
            try prepare(model: model)
            guard let loaded, let api = library else { throw ONNXInferenceError.runtime("The speech model is not loaded.") }
            let session = try DecodeSession(api: api, model: loaded.model, chunk: loaded.settings.chunkSamples)
            defer { session.close() }
            let cancelled = { () throws in
                try Task.checkCancellation()
                if cancellation.isCancelled { throw CancellationError() }
            }
            try session.feed(samples, cancelled: cancelled)
            try session.flush(cancelled: cancelled)
            let text = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.noSpeech }
            return text
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: Live streaming

    func beginStream(model: LocalModel) throws {
        closeStream()
        try prepare(model: model)
        guard let loaded, let api = library else { throw ONNXInferenceError.runtime("The speech model is not loaded.") }
        stream = try DecodeSession(api: api, model: loaded.model, chunk: loaded.settings.chunkSamples)
    }

    /// Feeds newly captured audio and returns the transcript so far.
    func feedStream(_ samples: [Float]) throws -> String {
        guard let stream else { return "" }
        try stream.feed(samples) { try Task.checkCancellation() }
        return stream.transcript
    }

    /// Feeds the tail of the recording, flushes the final chunk, and ends the stream.
    func finishStream(_ remaining: [Float]) throws -> String {
        guard let stream else { throw ONNXInferenceError.runtime("No live transcription is active.") }
        defer { closeStream() }
        try stream.feed(remaining) {}
        try stream.flush {}
        let text = stream.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.noSpeech }
        return text
    }

    func closeStream() {
        stream?.close()
        stream = nil
    }
}
