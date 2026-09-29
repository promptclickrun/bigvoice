import Foundation
import NaturalLanguage

/// One word of a transcript and what the cleaner decided about it. Removed words are kept in the list so
/// the interface can show exactly what was taken out.
public struct CleanToken: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case word, filler, repeated, corrected, lineBreak
    }

    public var text: String
    public var role: Role

    public init(text: String, role: Role) {
        self.text = text
        self.role = role
    }

    public var removed: Bool { role == .filler || role == .repeated || role == .corrected }
}

public struct CleanerOptions: Sendable, Equatable {
    public var level: PolishLevel
    public var tone: WritingTone
    public var vocabulary: [VocabularyTerm]
    public var spokenPunctuation: Bool
    /// English-only rules (fillers, single-word repeats, self-corrections, "i" → "I") are skipped otherwise.
    public var english: Bool
    /// False while words are still arriving, so a live preview never grows a premature period.
    public var closeSentence: Bool

    public init(level: PolishLevel, tone: WritingTone = .natural, vocabulary: [VocabularyTerm] = [],
                spokenPunctuation: Bool = false, english: Bool = true, closeSentence: Bool = true) {
        self.level = level
        self.tone = tone
        self.vocabulary = vocabulary
        self.spokenPunctuation = spokenPunctuation
        self.english = english
        self.closeSentence = closeSentence
    }

    public init(style: StylePreferences, context: WritingContext, english: Bool, closeSentence: Bool = true) {
        self.init(level: style.level, tone: style.tone(for: context), vocabulary: style.vocabulary,
                  spokenPunctuation: style.spokenPunctuation, english: english, closeSentence: closeSentence)
    }
}

/// The instant, rules-only layer. Every level above Verbatim starts here; language models only ever see
/// its output, and it is the safe fallback whenever a model is unavailable or changes the meaning.
public enum TranscriptCleaner {
    public static func clean(_ text: String, options: CleanerOptions) -> String {
        let prepared = prepare(text, options: options)
        guard options.level >= .clean else { return tidy(prepared) }
        return assemble(annotate(prepared: prepared, options: options), options: options)
    }

    public static func annotate(_ text: String, options: CleanerOptions) -> [CleanToken] {
        let prepared = prepare(text, options: options)
        guard options.level >= .clean else {
            return tokenize(prepared).map { CleanToken(text: $0, role: $0 == "\n" ? .lineBreak : .word) }
        }
        return annotate(prepared: prepared, options: options)
    }

    /// Final pass over language-model output: spacing, your spellings, and the tone's sentence ending.
    public static func finish(_ text: String, options: CleanerOptions) -> String {
        var result = tidy(text)
        if options.english && options.tone != .casual { result = capitalizeStandaloneI(result) }
        result = applyVocabulary(result, options.vocabulary)
        return closing(result, options: options)
    }

    public static func isEnglish(_ text: String, language: String) -> Bool {
        if language == "en" { return true }
        if language != "auto" { return false }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 16 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        if let english = hypotheses[.english], english >= 0.3 { return true }
        return recognizer.dominantLanguage == .english || recognizer.dominantLanguage == nil
    }

    // MARK: - Preparation

    private static func prepare(_ text: String, options: CleanerOptions) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        result = Regex.noiseTags.replace(in: result, with: " ")
        result = Regex.noiseParens.replace(in: result, with: " ")
        result = result.replacingOccurrences(of: "♪", with: " ")
        result = Regex.horizontalSpace.replace(in: result, with: " ")
        if options.spokenPunctuation { result = applySpokenPunctuation(result) }
        result = applyVocabulary(result, options.vocabulary)
        return result
    }

    private static func applySpokenPunctuation(_ text: String) -> String {
        var result = text
        for (pattern, template) in Regex.spokenCommands {
            result = pattern.replace(in: result, with: template)
        }
        return result
    }

    static func applyVocabulary(_ text: String, _ vocabulary: [VocabularyTerm]) -> String {
        guard !vocabulary.isEmpty else { return text }
        var pairs: [(String, String)] = []
        for entry in vocabulary where !entry.term.isEmpty {
            pairs.append((entry.term, entry.term))
            for alias in entry.heardAs { pairs.append((alias, entry.term)) }
        }
        var result = text
        for (spoken, written) in pairs.sorted(by: { $0.0.count > $1.0.count }) {
            let words = spoken.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s-]+") + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range,
                                                         withTemplate: NSRegularExpression.escapedTemplate(for: written))
        }
        return result
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { tokens.append("\n") }
            tokens += line.split(separator: " ").map(String.init)
        }
        return tokens
    }

    // MARK: - Annotation

    private static func annotate(prepared: String, options: CleanerOptions) -> [CleanToken] {
        var tokens = tokenize(prepared).map { CleanToken(text: $0, role: $0 == "\n" ? .lineBreak : .word) }
        if options.english {
            for index in tokens.indices where tokens[index].role == .word && Lexicon.fillers.contains(core(tokens[index].text)) {
                tokens[index].role = .filler
            }
        }
        markPartialWords(&tokens)
        markRepeats(&tokens, english: options.english)
        if options.english {
            markScratchThat(&tokens)
            markSelfCorrections(&tokens)
        }
        return tokens
    }

    /// "th- the" → "the".
    private static func markPartialWords(_ tokens: inout [CleanToken]) {
        let kept = tokens.indices.filter { tokens[$0].role == .word }
        for (position, index) in kept.enumerated().dropLast() {
            let text = tokens[index].text
            guard text.hasSuffix("-") || text.hasSuffix("—") else { continue }
            let fragment = core(text)
            let next = core(tokens[kept[position + 1]].text)
            if !fragment.isEmpty, fragment.count < next.count, next.hasPrefix(fragment) {
                tokens[index].role = .repeated
            }
        }
    }

    /// "we should, we should probably" → "we should probably"; "the the" → "the".
    private static func markRepeats(_ tokens: inout [CleanToken], english: Bool) {
        var changed = true
        while changed {
            changed = false
            let kept = tokens.indices.filter { tokens[$0].role == .word }
            let cores = kept.map { core(tokens[$0].text) }
            search: for n in stride(from: 4, through: english ? 1 : 2, by: -1) {
                var i = 0
                while i + 2 * n <= kept.count {
                    defer { i += 1 }
                    guard (0..<n).allSatisfy({ !cores[i + $0].isEmpty && cores[i + $0] == cores[i + n + $0] }) else { continue }
                    guard !endsSentence(tokens[kept[i + n - 1]].text) else { continue }
                    guard !tokens[kept[i]...kept[i + 2 * n - 1]].contains(where: { $0.role == .lineBreak }) else { continue }
                    let block = cores[i..<(i + n)]
                    if block.allSatisfy({ Lexicon.legitimateRepeats.contains($0) || isNumeric($0) }) { continue }
                    for offset in 0..<n { tokens[kept[i + offset]].role = .repeated }
                    changed = true
                    break search
                }
            }
        }
    }

    /// "Let's meet at noon. Scratch that. Let's meet at one." → "Let's meet at one."
    private static func markScratchThat(_ tokens: inout [CleanToken]) {
        var kept = tokens.indices.filter { tokens[$0].role == .word }
        var position = 0
        while position + 1 < kept.count {
            defer { position += 1 }
            guard core(tokens[kept[position]].text) == "scratch", core(tokens[kept[position + 1]].text) == "that" else { continue }
            var start = position
            while start > 0 && !endsSentence(tokens[kept[start - 1]].text) && !breakBetween(tokens, kept[start - 1], kept[start]) {
                start -= 1
            }
            if start == position && start > 0 {
                start -= 1
                while start > 0 && !endsSentence(tokens[kept[start - 1]].text) && !breakBetween(tokens, kept[start - 1], kept[start]) {
                    start -= 1
                }
            }
            for index in kept[start...(position + 1)] { tokens[index].role = .corrected }
            kept = tokens.indices.filter { tokens[$0].role == .word }
            position = max(-1, start - 1)
        }
    }

    /// "on Tuesday, actually no, Wednesday" → "on Wednesday"; "to Jake, I mean Jane" → "to Jane".
    /// Only swaps like for like (days, months, numbers, names), so an ordinary "actually" is untouched.
    private static func markSelfCorrections(_ tokens: inout [CleanToken]) {
        var kept = tokens.indices.filter { tokens[$0].role == .word }
        var position = 1
        while position < kept.count {
            defer { position += 1 }
            let cores = kept.map { core(tokens[$0].text) }
            guard let entry = Lexicon.correctionMarkers.first(where: { entry in
                position + entry.0.count <= cores.count && Array(cores[position..<(position + entry.0.count)]) == entry.0
            }) else { continue }
            let marker = entry.0, strong = entry.1
            var next = position + marker.count
            guard next < kept.count else { continue }
            let previous = position - 1
            guard !endsSentence(tokens[kept[previous]].text),
                  let category = category(of: kept, at: previous, in: tokens) else { continue }
            guard strong || category != .name else { continue }
            var start = previous
            while start > 0, !hasClausePunctuation(tokens[kept[start - 1]].text),
                  self.category(of: kept, at: start - 1, in: tokens) == category {
                start -= 1
            }
            // "on Tuesday, actually no, on Wednesday": the repeated preposition moves with the correction.
            if start > 0, Lexicon.prepositions.contains(cores[next]), cores[next] == cores[start - 1], next + 1 < kept.count {
                start -= 1
                next += 1
            }
            guard self.category(of: kept, at: next, in: tokens) == category else { continue }
            for index in kept[start..<(position + marker.count)] { tokens[index].role = .corrected }
            kept = tokens.indices.filter { tokens[$0].role == .word }
            position = start
        }
    }

    private enum Category { case day, month, number, name }

    private static func category(of kept: [Int], at position: Int, in tokens: [CleanToken]) -> Category? {
        let text = tokens[kept[position]].text
        let word = core(text)
        guard !word.isEmpty else { return nil }
        if Lexicon.days.contains(word) { return .day }
        if Lexicon.months.contains(word) {
            if !Lexicon.ambiguousMonths.contains(word) || text.first(where: \.isLetter)?.isUppercase == true { return .month }
        }
        if isNumeric(word) || Lexicon.numberWords.contains(word) { return .number }
        let sentenceStart = position == 0 || endsSentence(tokens[kept[position - 1]].text)
        if !sentenceStart, let first = text.first(where: \.isLetter), first.isUppercase, word.count > 1,
           word != "i", !word.hasPrefix("i'") {
            return .name
        }
        return nil
    }

    // MARK: - Assembly

    private static func assemble(_ tokens: [CleanToken], options: CleanerOptions) -> String {
        var pieces: [String] = []
        for token in tokens {
            if token.role == .lineBreak { pieces.append("\n"); continue }
            if token.removed {
                if let mark = terminalMark(token.text), let last = pieces.lastIndex(where: { $0 != "\n" }),
                   !endsSentence(pieces[last]) {
                    var word = pieces[last]
                    while let character = word.last, ",;:".contains(character) { word.removeLast() }
                    pieces[last] = word + mark
                } else if token.role == .filler, token.text.hasSuffix(","), let last = pieces.lastIndex(where: { $0 != "\n" }),
                          pieces[last].hasSuffix(","), !Lexicon.introductory.contains(core(pieces[last])) {
                    // "the build is, uh, green": those commas were the pause, not the grammar.
                    pieces[last].removeLast()
                }
                continue
            }
            pieces.append(token.text)
        }
        var text = ""
        for piece in pieces {
            if piece == "\n" {
                while text.last == " " { text.removeLast() }
                text += "\n"
            } else {
                if !text.isEmpty && text.last != "\n" { text += " " }
                text += piece
            }
        }
        text = tidy(text)
        if options.english && options.tone != .casual { text = capitalizeStandaloneI(text) }
        if options.tone == .casual {
            text = relaxSentenceStarts(text, vocabulary: options.vocabulary)
        } else if !isShortCommand(text, tone: options.tone) {
            text = capitalizeSentenceStarts(text)
        }
        text = applyVocabulary(text, options.vocabulary)
        return closing(text, options: options)
    }

    /// In code and terminals a few words are usually a command or identifier; "git status" must stay as typed.
    private static func isShortCommand(_ text: String, tone: WritingTone) -> Bool {
        tone == .technical && text.split(whereSeparator: \.isWhitespace).count < 4
    }

    private static func closing(_ text: String, options: CleanerOptions) -> String {
        guard options.closeSentence, !text.isEmpty else { return text }
        var result = text
        if options.tone == .casual {
            if result.hasSuffix(".") && !result.hasSuffix("..") { result.removeLast() }
            return result
        }
        while let last = result.last, ",;".contains(last) { result.removeLast() }
        guard let last = result.last, !isShortCommand(result, tone: options.tone) else { return result }
        if last.isLetter || last.isNumber || "\"”’')".contains(last) { result += "." }
        return result
    }

    // MARK: - Text utilities

    static func tidy(_ text: String) -> String {
        var result = text
        for (pattern, template) in Regex.tidy {
            result = pattern.replace(in: result, with: template)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeStandaloneI(_ text: String) -> String {
        Regex.standaloneI.replace(in: text, with: "I$1")
    }

    private static func capitalizeSentenceStarts(_ text: String) -> String {
        transformSentenceStarts(text) { word in
            guard let first = word.first, first.isLowercase else { return word }
            // Mixed case such as iPhone or macOS is intentional.
            if word.dropFirst().contains(where: \.isUppercase) { return word }
            return first.uppercased() + word.dropFirst()
        }
    }

    private static func relaxSentenceStarts(_ text: String, vocabulary: [VocabularyTerm]) -> String {
        let terms = Set(vocabulary.map { $0.term.split(separator: " ").first.map(String.init) ?? $0.term })
        return transformSentenceStarts(text) { word in
            guard let first = word.first, first.isUppercase else { return word }
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            if bare == "I" || bare.hasPrefix("I'") || bare.hasPrefix("I’") || terms.contains(bare) { return word }
            if word.dropFirst().contains(where: \.isUppercase) { return word }
            return first.lowercased() + word.dropFirst()
        }
    }

    private static func transformSentenceStarts(_ text: String, _ transform: (String) -> String) -> String {
        var result = ""
        var atStart = true
        var afterTerminal = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if atStart && character.isLetter {
                let end = text[index...].firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
                result += transform(String(text[index..<end]))
                index = end
                atStart = false
                afterTerminal = false
                continue
            }
            result.append(character)
            if character == "\n" {
                atStart = true
            } else if ".!?".contains(character) {
                afterTerminal = true
            } else if character.isWhitespace {
                if afterTerminal { atStart = true }
            } else if character.isLetter || character.isNumber {
                atStart = false
                afterTerminal = false
            } else if afterTerminal && !"\"”’')".contains(character) {
                afterTerminal = false
            }
            index = text.index(after: index)
        }
        return result
    }

    static func core(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces))
            .replacingOccurrences(of: "’", with: "'")
    }

    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"”’')"))
        return trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") || trimmed.hasSuffix("…")
    }

    private static func hasClausePunctuation(_ text: String) -> Bool {
        endsSentence(text) || text.hasSuffix(",") || text.hasSuffix(";") || text.hasSuffix(":")
    }

    /// Sentence punctuation a removed word was carrying. A trailing ellipsis on a filler is hesitation, not an ending.
    private static func terminalMark(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"”’')"))
        guard let last = trimmed.last, ".?!".contains(last), !trimmed.hasSuffix("..") else { return nil }
        return String(last)
    }

    private static func breakBetween(_ tokens: [CleanToken], _ a: Int, _ b: Int) -> Bool {
        a < b && tokens[a...b].contains { $0.role == .lineBreak }
    }

    private static func isNumeric(_ word: String) -> Bool {
        Regex.numeric.matches(word)
    }
}

// MARK: - Word lists

enum Lexicon {
    static let fillers: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "uhmm", "erm", "er", "hmm", "hmmm", "hm", "mm", "mmm", "ehm"
    ]

    /// Single words people repeat on purpose.
    static let legitimateRepeats: Set<String> = [
        "had", "that", "is", "do", "very", "really", "so", "no", "yes", "yeah", "bye", "ha", "haha", "hey", "knock",
        "tut", "well", "now", "there", "go", "again", "more", "many", "much", "far", "long", "on", "over", "round",
        "and", "blah", "la", "ho", "yay", "wow", "please", "come", "hear", "chop", "quick", "pretty", "boo"
    ]

    /// Longest markers first. `true` means strong enough to swap names.
    static let correctionMarkers: [([String], Bool)] = [
        (["actually", "no"], true), (["no", "wait"], true), (["wait", "no"], true), (["or", "rather"], true),
        (["sorry", "no"], true), (["no", "sorry"], true), (["i", "mean"], true),
        (["actually"], false), (["sorry"], false), (["rather"], false), (["wait"], false)
    ]

    static let days: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "today", "tomorrow", "tonight", "yesterday"
    ]
    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december"
    ]
    static let ambiguousMonths: Set<String> = ["march", "may", "august"]
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "noon", "midnight", "half", "quarter"
    ]
    static let prepositions: Set<String> = ["on", "at", "to", "by", "in", "for", "from", "with", "until", "before", "after"]
    /// Words whose trailing comma is real grammar, so it stays when a following filler is removed.
    static let introductory: Set<String> = [
        "yes", "yeah", "yep", "no", "nope", "so", "well", "okay", "ok", "oh", "hey", "hi", "hello", "right", "now",
        "first", "second", "third", "also", "however", "anyway", "actually", "sure", "thanks", "honestly", "basically"
    ]
}

// MARK: - Expressions

struct Pattern: @unchecked Sendable {
    let expression: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        // Patterns are compile-time constants; a failure here is a programming error caught by the test suite.
        expression = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func replace(in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    func matches(_ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

enum Regex {
    static let noiseTags = Pattern("\\[\\s*[A-Za-z_ ]{2,30}\\s*\\]")
    static let noiseParens = Pattern(
        "\\(\\s*(?:music|laughs?|laughter|laughing|applause|coughs?|coughing|sighs?|inaudible|silence|noise|background noise|static|clears throat|beeps?|breathing)\\s*\\)",
        caseInsensitive: true)
    static let horizontalSpace = Pattern("[ \\t\\u00A0]+")
    static let numeric = Pattern("^\\$?\\d+(?:[:.,]\\d+)*(?:am|pm|%|k|st|nd|rd|th)?$", caseInsensitive: true)
    static let standaloneI = Pattern("(?<![\\p{L}\\p{N}.'’])i((?:['’](?:m|ve|ll|d))?)(?=[\\s,;:!?)\"”]|$|\\.(?:\\s|$))")

    static let spokenCommands: [(Pattern, String)] = [
        (Pattern("[ ,.;:]*\\bnew paragraph\\b[ ,.;:]*", caseInsensitive: true), "\n\n"),
        (Pattern("[ ,.;:]*\\bnew line\\b[ ,.;:]*", caseInsensitive: true), "\n"),
        (Pattern("[ ,]*\\b(?:question mark)\\b[,.]?", caseInsensitive: true), "?"),
        (Pattern("[ ,]*\\b(?:exclamation (?:point|mark))\\b[,.]?", caseInsensitive: true), "!"),
        (Pattern("[ ,]*\\bfull stop\\b[,.]?", caseInsensitive: true), "."),
        (Pattern("[ ,]*\\bperiod[,.!?]?(?=\\s*(?:\\n|$))", caseInsensitive: true), "."),
        (Pattern("[ ,]*\\bsemicolon\\b[,.]?", caseInsensitive: true), ";"),
        (Pattern("[ ,]*\\bcolon\\b[,.]?", caseInsensitive: true), ":"),
        (Pattern("[ ,]*\\bcomma\\b[,.]?", caseInsensitive: true), ",")
    ]

    static let tidy: [(Pattern, String)] = [
        (Pattern("[ \\t]+\\n"), "\n"),
        (Pattern("\\n[ \\t]+"), "\n"),
        (Pattern("\\n{3,}"), "\n\n"),
        (Pattern("[ \\t]{2,}"), " "),
        (Pattern("[ \\t]+([,.;:!?%)\\]}])"), "$1"),
        (Pattern(",{2,}"), ","),
        (Pattern("[,;:]+([.!?])"), "$1"),
        (Pattern("([.!?])[,;:]+"), "$1"),
        (Pattern("([!?])\\.(?!\\.)"), "$1"),
        (Pattern("(?<!\\.)\\.\\.(?!\\.)"), "."),
        (Pattern("(^|\\n)[ \\t]*[,;:.]+[ \\t]*"), "$1")
    ]
}
