import Foundation

/// How far bigvoice moves from what was heard toward text that is ready to send.
public enum PolishLevel: String, Codable, CaseIterable, Sendable, Comparable {
    /// Exactly what the speech model heard.
    case verbatim
    /// Rules only: fillers, stutters, obvious self-corrections, capitals, and punctuation. Instant.
    case clean
    /// A local language model fixes grammar and punctuation while keeping the speaker's words.
    case polished
    /// A local language model tightens and restructures in the chosen tone.
    case refined

    public var usesLanguageModel: Bool { self == .polished || self == .refined }

    public var title: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean"
        case .polished: return "Polished"
        case .refined: return "Refined"
        }
    }

    public var summary: String {
        switch self {
        case .verbatim: return "Exactly what the model heard. Nothing added, nothing taken away."
        case .clean: return "Ums, stutters, and false starts removed. Capitals and punctuation fixed. Instant."
        case .polished: return "Grammar and punctuation fixed on this Mac. Your words and order stay yours."
        case .refined: return "Tightened into a ready-to-send message in the tone you choose."
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum WritingTone: String, Codable, CaseIterable, Sendable {
    case natural, professional, friendly, casual, technical

    public var title: String {
        switch self {
        case .natural: return "Natural"
        case .professional: return "Professional"
        case .friendly: return "Friendly"
        case .casual: return "Casual"
        case .technical: return "Technical"
        }
    }

    public var summary: String {
        switch self {
        case .natural: return "Sounds like you, minus the stumbles."
        case .professional: return "Clear, courteous, complete sentences."
        case .friendly: return "Warm and upbeat. Contractions welcome."
        case .casual: return "texting style, lowercase, easy on the punctuation"
        case .technical: return "Precise. Code, paths, and names kept exact."
        }
    }
}

/// Where the words are going. Chosen from the app that had focus when dictation started.
public enum WritingContext: String, Codable, CaseIterable, Sendable {
    case messages, email, documents, code, other

    public var title: String {
        switch self {
        case .messages: return "Messages"
        case .email: return "Email"
        case .documents: return "Documents & notes"
        case .code: return "Code & terminals"
        case .other: return "Everywhere else"
        }
    }

    public var shortTitle: String {
        switch self {
        case .messages: return "Messages"
        case .email: return "Email"
        case .documents: return "Docs"
        case .code: return "Code"
        case .other: return "Elsewhere"
        }
    }

    public var examples: String {
        switch self {
        case .messages: return "Messages, Slack, Discord, Teams, WhatsApp, Telegram, Signal"
        case .email: return "Mail, Outlook, Spark, Superhuman, Mimestream"
        case .documents: return "Notes, Pages, Word, Notion, Obsidian, Bear, TextEdit"
        case .code: return "Xcode, VS Code, Cursor, Zed, Terminal, iTerm, GitHub Copilot"
        case .other: return "Browsers and every other app"
        }
    }

    public var defaultTone: WritingTone {
        switch self {
        case .email: return .professional
        case .code: return .technical
        default: return .natural
        }
    }

    private static let exact: [String: WritingContext] = [
        "com.apple.MobileSMS": .messages, "com.apple.iChat": .messages,
        "com.tinyspeck.slackmacgap": .messages, "com.hnc.Discord": .messages,
        "com.microsoft.teams": .messages, "com.microsoft.teams2": .messages,
        "net.whatsapp.WhatsApp": .messages, "desktop.WhatsApp": .messages,
        "ru.keepcoder.Telegram": .messages, "org.telegram.desktop": .messages,
        "org.whispersystems.signal-desktop": .messages, "com.facebook.archon": .messages,
        "com.apple.mail": .email, "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email, "com.superhuman.electron": .email,
        "com.mimestream.Mimestream": .email, "it.bloop.airmail2": .email, "com.freron.MailMate": .email,
        "com.apple.Notes": .documents, "com.apple.iWork.Pages": .documents, "com.microsoft.Word": .documents,
        "notion.id": .documents, "md.obsidian": .documents, "com.apple.TextEdit": .documents,
        "net.shinyfrog.bear": .documents, "com.ulyssesapp.mac": .documents,
        "com.microsoft.onenote.mac": .documents, "com.agiletortoise.Drafts-OSX": .documents,
        "com.evernote.Evernote": .documents, "com.lukilabs.lukiapp": .documents,
        "com.apple.dt.Xcode": .code, "com.microsoft.VSCode": .code, "com.microsoft.VSCodeInsiders": .code,
        "com.todesktop.230313mzl4w4u92": .code, "dev.zed.Zed": .code, "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code, "dev.warp.Warp-Stable": .code, "com.mitchellh.ghostty": .code,
        "com.sublimetext.4": .code, "com.panic.Nova": .code, "com.github.githubapp": .code,
        "com.exafunction.windsurf": .code
    ]

    public static func classify(bundleIdentifier: String?) -> WritingContext {
        guard let identifier = bundleIdentifier, !identifier.isEmpty else { return .other }
        if let context = exact[identifier] { return context }
        if identifier.hasPrefix("com.jetbrains.") || identifier.hasPrefix("com.google.android.studio") { return .code }
        return .other
    }
}

/// A word bigvoice should always spell your way, optionally with what the speech model tends to hear instead.
public struct VocabularyTerm: Codable, Hashable, Sendable, Identifiable {
    public var term: String
    public var heardAs: [String]

    public var id: String { term.lowercased() }

    public init(term: String, heardAs: [String] = []) {
        self.term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        self.heardAs = heardAs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != term.lowercased() }
    }
}

public enum PolishEngineChoice: String, Codable, CaseIterable, Sendable {
    /// Apple Intelligence when it's on, otherwise a chat model already installed in Ollama.
    case automatic
    case appleIntelligence
    case ollama
}

public struct StylePreferences: Codable, Equatable, Sendable {
    public static let maximumInstructionLength = 400
    public static let maximumVocabulary = 150

    public var level: PolishLevel = .polished
    /// Keyed by `WritingContext.rawValue`; a missing key means that context's default tone.
    public var tones: [String: WritingTone] = [:]
    public var customInstructions = ""
    public var vocabulary: [VocabularyTerm] = []
    public var spokenPunctuation = false
    public var engine: PolishEngineChoice = .automatic
    public var ollamaModel: String?

    public init() {}

    public func tone(for context: WritingContext) -> WritingTone {
        tones[context.rawValue] ?? context.defaultTone
    }

    public mutating func setTone(_ tone: WritingTone, for context: WritingContext) {
        tones[context.rawValue] = tone == context.defaultTone ? nil : tone
    }

    private enum CodingKeys: String, CodingKey {
        case level, tones, customInstructions, vocabulary, spokenPunctuation, engine, ollamaModel
    }

    /// Tolerant on purpose: an unknown value from a newer build falls back to a default instead of
    /// discarding every other preference.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try? container.decodeIfPresent(String.self, forKey: .level), let level = PolishLevel(rawValue: raw) {
            self.level = level
        }
        if let raw = try? container.decodeIfPresent([String: String].self, forKey: .tones) {
            tones = raw.reduce(into: [:]) { result, pair in
                if WritingContext(rawValue: pair.key) != nil, let tone = WritingTone(rawValue: pair.value) {
                    result[pair.key] = tone
                }
            }
        }
        customInstructions = String(((try? container.decodeIfPresent(String.self, forKey: .customInstructions)) ?? "")
            .prefix(Self.maximumInstructionLength))
        vocabulary = Array(((try? container.decodeIfPresent([VocabularyTerm].self, forKey: .vocabulary)) ?? [])
            .filter { !$0.term.isEmpty }.prefix(Self.maximumVocabulary))
        spokenPunctuation = (try? container.decodeIfPresent(Bool.self, forKey: .spokenPunctuation)) ?? false
        if let raw = try? container.decodeIfPresent(String.self, forKey: .engine), let engine = PolishEngineChoice(rawValue: raw) {
            self.engine = engine
        }
        ollamaModel = try? container.decodeIfPresent(String.self, forKey: .ollamaModel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(level, forKey: .level)
        try container.encode(tones.mapValues(\.rawValue), forKey: .tones)
        try container.encode(customInstructions, forKey: .customInstructions)
        try container.encode(vocabulary, forKey: .vocabulary)
        try container.encode(spokenPunctuation, forKey: .spokenPunctuation)
        try container.encode(engine, forKey: .engine)
        try container.encodeIfPresent(ollamaModel, forKey: .ollamaModel)
    }
}
