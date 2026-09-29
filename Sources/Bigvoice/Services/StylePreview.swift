import BigvoiceCore
import BigvoiceRuntime
import Foundation

/// Live specimens for the Style page: the same pipeline dictation uses, run on sample speech for each
/// app context. Rules-only levels resolve instantly; model levels resolve one card at a time, keeping the
/// previous words on screen until the new ones are ready.
@MainActor
final class StylePreview: ObservableObject {
    static let samples: [WritingContext: String] = [
        .messages: "um hey are you still good for lunch tomorrow uh maybe around noon actually no one",
        .email: "hi sam so um i wanted to follow up on the the proposal we sent last week and see if you had any questions",
        .documents: "the main risk is uh timeline slip because the vendor hasn't um confirmed the the delivery date yet",
        .code: "um rename the the parse config function to load config and update the call sites",
        .other: "so i think we should uh go with the smaller model it's it's faster and the quality is basically the same"
    ]

    @Published private(set) var outcomes: [WritingContext: PolishOutcome] = [:]
    @Published private(set) var pending: Set<WritingContext> = []
    var polish: ((String, StylePreferences, WritingContext) async throws -> PolishOutcome)?
    private var keys: [WritingContext: String] = [:]
    private var requested: String?
    private var current: UUID?
    private var task: Task<Void, Never>?

    /// Typical model latency from the specimens just run, for the level axis readout.
    var measuredMilliseconds: Int? {
        let timed = outcomes.values.filter { $0.applied.usesLanguageModel }.map(\.milliseconds)
        guard !timed.isEmpty else { return nil }
        return timed.sorted()[timed.count / 2]
    }

    func update(style: StylePreferences, engineKey: String, delay: Duration = .milliseconds(380)) {
        let overall = WritingContext.allCases.map { Self.key(style, $0, engineKey) }.joined(separator: "¦")
        guard overall != requested else { return }
        requested = overall
        task?.cancel()
        var queue: [WritingContext] = []
        for context in WritingContext.allCases {
            let key = Self.key(style, context, engineKey)
            if keys[context] == key, outcomes[context] != nil { continue }
            if style.level.usesLanguageModel {
                if outcomes[context] == nil { outcomes[context] = rules(style, context, level: .clean) }
                queue.append(context)
            } else {
                outcomes[context] = rules(style, context, level: style.level)
                keys[context] = key
            }
        }
        pending = Set(queue)
        guard !queue.isEmpty, let polish else { pending = []; return }
        let token = UUID()
        current = token
        task = Task { [weak self] in
            // Whatever ends this run (done, failed, or superseded), no card is left shimmering for it.
            defer { if self?.current == token { self?.pending = [] } }
            if delay > .zero { try? await Task.sleep(for: delay) }
            for context in queue {
                guard !Task.isCancelled, let sample = Self.samples[context] else { return }
                do {
                    let outcome = try await polish(sample, style, context)
                    guard !Task.isCancelled, let self else { return }
                    self.outcomes[context] = outcome
                    self.keys[context] = Self.key(style, context, engineKey)
                    self.pending.remove(context)
                } catch {
                    return
                }
            }
        }
    }

    /// Waits for every pending specimen; used when rendering previews.
    func settle() async {
        await task?.value
    }

    private func rules(_ style: StylePreferences, _ context: WritingContext, level: PolishLevel) -> PolishOutcome {
        let sample = Self.samples[context] ?? ""
        var options = CleanerOptions(style: style, context: context, english: true)
        options.level = level
        return PolishOutcome(text: TranscriptCleaner.clean(sample, options: options), heard: sample, requested: style.level,
                             applied: level, tone: style.tone(for: context), context: context)
    }

    private static func key(_ style: StylePreferences, _ context: WritingContext, _ engine: String) -> String {
        [style.level.rawValue, style.tone(for: context).rawValue, style.customInstructions,
         style.vocabulary.map { $0.term + ":" + $0.heardAs.joined(separator: ",") }.joined(separator: ";"),
         String(style.spokenPunctuation), style.level.usesLanguageModel ? engine : ""].joined(separator: "|")
    }
}
