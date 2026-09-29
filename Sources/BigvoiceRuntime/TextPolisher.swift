import BigvoiceCore
import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleIntelligenceState: Equatable, Sendable {
    case available, notEnabled, preparing, unsupportedDevice, unsupportedSystem

    public var label: String {
        switch self {
        case .available: return "Ready"
        case .notEnabled: return "Turned off"
        case .preparing: return "Downloading"
        case .unsupportedDevice: return "Not on this Mac"
        case .unsupportedSystem: return "Needs macOS 26"
        }
    }

    public var detail: String {
        switch self {
        case .available: return "Built into macOS. Runs on this Mac and adds nothing to your disk."
        case .notEnabled: return "Turn on Apple Intelligence in System Settings to polish with the model macOS already has."
        case .preparing: return "macOS is still downloading its on-device model. Polish starts working when it finishes."
        case .unsupportedDevice: return "This Mac can't run Apple Intelligence. Clean still works, and so does Ollama."
        case .unsupportedSystem: return "Apple's on-device model arrives with macOS 26. Clean works everywhere."
        }
    }
}

public struct OllamaState: Equatable, Sendable {
    public var installed: Bool
    public var running: Bool
    /// Chat-capable models only; embedding models can't rewrite text.
    public var models: [String]

    public init(installed: Bool = false, running: Bool = false, models: [String] = []) {
        self.installed = installed
        self.running = running
        self.models = models
    }
}

public enum WritingEngine: Equatable, Sendable {
    case appleIntelligence
    case ollama(model: String)

    public var label: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .ollama(let model): return "Ollama · \(model)"
        }
    }
}

public struct WritingEngineStatus: Equatable, Sendable {
    public var appleIntelligence: AppleIntelligenceState
    public var ollama: OllamaState

    public init(appleIntelligence: AppleIntelligenceState, ollama: OllamaState) {
        self.appleIntelligence = appleIntelligence
        self.ollama = ollama
    }

    public func engine(for style: StylePreferences) -> WritingEngine? {
        let ollamaModel: String? = {
            guard ollama.running, !ollama.models.isEmpty else { return nil }
            if let chosen = style.ollamaModel, ollama.models.contains(chosen) { return chosen }
            return ollama.models.first
        }()
        switch style.engine {
        case .automatic:
            if appleIntelligence == .available { return .appleIntelligence }
            return ollamaModel.map { .ollama(model: $0) }
        case .appleIntelligence:
            return appleIntelligence == .available ? .appleIntelligence : nil
        case .ollama:
            return ollamaModel.map { .ollama(model: $0) }
        }
    }

    /// Why Polished or Refined can't run right now, in words for the interface.
    public func unavailableReason(for style: StylePreferences) -> String {
        switch style.engine {
        case .ollama:
            if !ollama.installed { return "Ollama isn't installed" }
            if !ollama.running { return "Ollama isn't running" }
            return "Ollama has no chat models"
        case .appleIntelligence, .automatic:
            return "Apple Intelligence is \(appleIntelligence.label.lowercased())"
        }
    }
}

/// What happened to one dictation on its way from heard to delivered.
public struct PolishOutcome: Equatable, Sendable {
    public var text: String
    public var heard: String
    public var requested: PolishLevel
    public var applied: PolishLevel
    public var tone: WritingTone
    public var context: WritingContext
    public var engine: WritingEngine?
    /// Set when a higher level was requested but a lower one was delivered.
    public var note: String?
    public var milliseconds: Int

    public init(text: String, heard: String, requested: PolishLevel, applied: PolishLevel, tone: WritingTone,
                context: WritingContext, engine: WritingEngine? = nil, note: String? = nil, milliseconds: Int = 0) {
        self.text = text
        self.heard = heard
        self.requested = requested
        self.applied = applied
        self.tone = tone
        self.context = context
        self.engine = engine
        self.note = note
        self.milliseconds = milliseconds
    }

    public var summary: String {
        applied == .verbatim ? "Verbatim" : "\(applied.title) · \(tone.title)"
    }
}

struct PolishTimeout: LocalizedError {
    var errorDescription: String? { "took too long" }
}

/// Turns what was heard into what should be delivered. Rules run first and always; a local writing model
/// runs on top only when asked, and only its answers that `PolishGuard` accepts are ever used.
public actor TextPolisher {
    public static let wordLimit = 1_000
    private let endpoint: URL
    private let urlSession: URLSession
    private var warmed: (key: String, session: AnyObject)?
    private var lastOllama = OllamaState()
    private var lastOllamaCheck: ContinuousClock.Instant?

    public init(ollamaEndpoint: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession? = nil) {
        endpoint = ollamaEndpoint
        if let session {
            urlSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = false
            configuration.urlCache = nil
            urlSession = URLSession(configuration: configuration)
        }
    }

    public static var appleIntelligenceState: AppleIntelligenceState {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleEngine.state }
        #endif
        return .unsupportedSystem
    }

    public func status(refresh: Bool = true) async -> WritingEngineStatus {
        let apple = Self.appleIntelligenceState
        let stale = lastOllamaCheck.map { ContinuousClock.now - $0 > .seconds(20) } ?? true
        if refresh || stale { lastOllama = await probeOllama() }
        return WritingEngineStatus(appleIntelligence: apple, ollama: lastOllama)
    }

    /// Loads Apple's model while the speaker is still talking, so polishing starts warm.
    public func prewarm(style: StylePreferences, context: WritingContext, appName: String?) {
        guard style.level.usesLanguageModel, style.engine != .ollama else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AppleEngine.state == .available {
            let request = PolishRequest(text: "", level: style.level, style: style, context: context, appName: appName)
            let instructions = PolishPrompt.instructions(for: request)
            if warmed?.key == instructions { return }
            let session = AppleEngine.session(instructions: instructions)
            session.prewarm()
            warmed = (instructions, session)
        }
        #endif
    }

    /// Only cancellation throws. Every other failure delivers the Clean text with a note explaining why.
    public func polish(_ heard: String, style: StylePreferences, context: WritingContext, appName: String?,
                       language: String, budget: Duration = .seconds(8)) async throws -> PolishOutcome {
        let started = ContinuousClock.now
        let english = TranscriptCleaner.isEnglish(heard, language: language)
        let options = CleanerOptions(style: style, context: context, english: english)
        let clean = TranscriptCleaner.clean(heard, options: options)
        let tone = style.tone(for: context)
        func outcome(_ text: String, _ applied: PolishLevel, _ engine: WritingEngine? = nil, note: String? = nil) -> PolishOutcome {
            let elapsed = ContinuousClock.now - started
            let milliseconds = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            return PolishOutcome(text: text, heard: heard, requested: style.level, applied: applied, tone: tone,
                                 context: context, engine: engine, note: note, milliseconds: milliseconds)
        }
        guard style.level.usesLanguageModel else { return outcome(clean, style.level) }
        guard !clean.isEmpty else { return outcome(clean, .clean) }
        if clean.split(whereSeparator: \.isWhitespace).count > Self.wordLimit {
            return outcome(clean, .clean, note: "Long dictations are cleaned, not rewritten")
        }
        let status = await status(refresh: style.engine == .ollama || lastOllamaCheck == nil)
        try Task.checkCancellation()
        guard let engine = status.engine(for: style) else {
            return outcome(clean, .clean, note: status.unavailableReason(for: style))
        }

        var note: String?
        for level in style.level == .refined ? [PolishLevel.refined, .polished] : [.polished] {
            let remaining = budget - (ContinuousClock.now - started)
            guard remaining > .milliseconds(300) else { note = note ?? "took too long"; break }
            let request = PolishRequest(text: clean, level: level, style: style, context: context, appName: appName)
            do {
                let raw = try await generate(request, engine: engine, timeout: remaining)
                let candidate = PolishGuard.sanitize(raw, source: clean)
                switch PolishGuard.evaluate(source: clean, candidate: candidate, level: level, english: english) {
                case .accepted:
                    return outcome(TranscriptCleaner.finish(candidate, options: options), level, engine,
                                   note: level == style.level ? nil : note.map { "Refined \($0), so Polished was used" })
                case .rejected(let reason):
                    Logger.polish.info("Rejected a \(level.rawValue, privacy: .public) rewrite: \(reason, privacy: .public)")
                    note = reason
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                Logger.polish.error("Writing model failed: \(error.localizedDescription, privacy: .public)")
                note = Self.describe(error)
                break
            }
        }
        return outcome(clean, .clean, engine, note: note.map { "\(engine.label) \($0)" })
    }

    public func generate(_ request: PolishRequest, engine: WritingEngine, timeout: Duration = .seconds(8)) async throws -> String {
        let instructions = PolishPrompt.instructions(for: request)
        let prompt = PolishPrompt.prompt(for: request)
        let tokens = PolishPrompt.maximumResponseTokens(for: request.text)
        switch engine {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session: LanguageModelSession
                if let warmed, warmed.key == instructions, let reused = warmed.session as? LanguageModelSession {
                    session = reused
                } else {
                    session = AppleEngine.session(instructions: instructions)
                }
                warmed = nil
                let box = Unchecked(session)
                return try await Self.withTimeout(timeout) {
                    try await AppleEngine.respond(box.value, prompt: prompt, maximumTokens: tokens)
                }
            }
            #endif
            throw PolishEngineError.unavailable
        case .ollama(let model):
            let body = OllamaChatRequest(model: model, messages: [.init(role: "system", content: instructions),
                                                                  .init(role: "user", content: prompt)],
                                         options: .init(temperature: 0, num_predict: tokens))
            var urlRequest = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(body)
            let session = urlSession, request = urlRequest
            return try await Self.withTimeout(timeout) {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PolishEngineError.ollamaStatus }
                let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
                return decoded.message.content
            }
        }
    }

    // MARK: - Ollama

    private func probeOllama() async -> OllamaState {
        lastOllamaCheck = .now
        let paths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app"]
        let installed = paths.contains { FileManager.default.fileExists(atPath: $0) }
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return OllamaState(installed: installed) }
            let tags = try JSONDecoder().decode(OllamaTags.self, from: data)
            let models = tags.models.filter(\.canChat).map(\.name).sorted()
            return OllamaState(installed: true, running: true, models: models)
        } catch {
            return OllamaState(installed: installed)
        }
    }

    // MARK: - Helpers

    static func describe(_ error: Error) -> String {
        if error is PolishTimeout { return "took too long" }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let description = AppleEngine.describe(error) { return description }
        #endif
        if let error = error as? PolishEngineError { return error.shortDescription }
        if (error as? URLError) != nil { return "couldn't be reached" }
        return "couldn't finish"
    }

    /// Resumes on whichever comes first: the answer, the deadline, or cancellation. A task group would wait
    /// for a model that ignores cancellation; this abandons it instead.
    static func withTimeout<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = TimeoutGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let work = Task {
                    do { gate.finish(.success(try await operation())) } catch { gate.finish(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(for: duration)
                    gate.finish(.failure(PolishTimeout()))
                }
                gate.track(work, timer)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

private final class TimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func track(_ tasks: Task<Void, Never>...) {
        lock.lock()
        if result != nil {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }
        self.tasks = tasks
        lock.unlock()
    }

    func finish(_ outcome: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        continuation?.resume(with: outcome)
        tasks.forEach { $0.cancel() }
    }
}

enum PolishEngineError: LocalizedError {
    case unavailable, ollamaStatus
    var shortDescription: String {
        switch self {
        case .unavailable: return "isn't available"
        case .ollamaStatus: return "returned an error"
        }
    }
    var errorDescription: String? { shortDescription }
}

private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private struct OllamaChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    struct Options: Encodable { let temperature: Double; let num_predict: Int }
    let model: String
    let messages: [Message]
    var stream = false
    /// Reasoning models otherwise spend the budget thinking out loud.
    var think = false
    var keep_alive = "10m"
    let options: Options
}

private struct OllamaChatResponse: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message
}

private struct OllamaTags: Decodable {
    struct Model: Decodable {
        struct Details: Decodable { let family: String? }
        let name: String
        let capabilities: [String]?
        let details: Details?

        var canChat: Bool {
            if let capabilities { return capabilities.contains("completion") }
            let family = details?.family?.lowercased() ?? ""
            return !name.lowercased().contains("embed") && !family.contains("bert")
        }
    }
    let models: [Model]
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private enum AppleEngine {
    static var state: AppleIntelligenceState {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .preparing
            case .deviceNotEligible: return .unsupportedDevice
            @unknown default: return .unsupportedDevice
            }
        }
    }

    /// Dictation is content to transform, not a conversation, so the permissive transformation guardrails apply.
    static func session(instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: instructions)
    }

    static func respond(_ session: LanguageModelSession, prompt: String, maximumTokens: Int) async throws -> String {
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumTokens)
        return try await session.respond(to: prompt, options: options).content
    }

    static func describe(_ error: Error) -> String? {
        guard let error = error as? LanguageModelSession.GenerationError else { return nil }
        switch error {
        case .exceededContextWindowSize: return "found this too long"
        case .guardrailViolation, .refusal: return "declined to edit this"
        case .unsupportedLanguageOrLocale: return "doesn't support this language yet"
        case .rateLimited, .concurrentRequests: return "was busy"
        case .assetsUnavailable: return "is still downloading"
        default: return "couldn't finish"
        }
    }
}
#endif

extension Logger {
    static let polish = Logger(subsystem: "com.bigvoice.mac", category: "polish")
}
