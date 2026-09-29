import AppKit
import BigvoiceCore
import BigvoiceRuntime
import SwiftUI

/*
 THESIS: One axis, five apps. The level is a single physical control; moving it rewrites every app's
 specimen at once, so the balance between verbatim and ready-to-send is felt, not read about.
 OWN-WORLD: bigvoice V2 as built: warm dark cards, paper words, Signal only for the axis fill and delivery.
 STORY: See what was heard, what got struck, and what lands, per app; pick a tone where it matters.
 FIRST VIEWPORT: Title, then the axis panel (level name at a display weight that grows with the level),
 then the first context cards. FORM: per-app specimen cards driven by one axis.
 */
struct StyleView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preview: StylePreview

    private var style: StylePreferences { controller.preferences.value.style }

    private func binding<Value>(_ path: WritableKeyPath<StylePreferences, Value>) -> Binding<Value> {
        Binding(get: { controller.preferences.value.style[keyPath: path] },
                set: { controller.preferences.value.style[keyPath: path] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            PageTitle(title: "Say it loosely. Send it ready.",
                      subtitle: "Choose how far bigvoice moves from what it heard, and how your words should sound in each app. All of it happens on this Mac.")
            LevelPanel(controller: controller, preview: preview, level: binding(\.level))
            contexts
            words
            instructions
            engine
        }
        .onAppear {
            controller.refreshWritingStatus()
            refreshPreview()
        }
        .onChange(of: style) { _, _ in refreshPreview() }
        .onChange(of: controller.writingEngine) { _, _ in refreshPreview() }
    }

    private func refreshPreview() {
        preview.update(style: style, engineKey: controller.writingEngine?.label ?? "none")
    }

    private var contexts: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("How you sound in each app",
                           detail: "bigvoice notices where you're dictating and writes for it. Each card runs the real pipeline on this Mac.")
            VStack(spacing: 12) {
                ForEach(WritingContext.allCases, id: \.self) { context in
                    ContextCard(context: context, style: style, outcome: preview.outcomes[context],
                                pending: preview.pending.contains(context),
                                tone: Binding(get: { style.tone(for: context) },
                                              set: { controller.preferences.value.style.setTone($0, for: context) }))
                }
            }
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Your words", detail: "Names, products, and jargon, spelled your way at every level, even Verbatim.")
            Panel {
                VocabularyEditor(controller: controller)
                RowDivider()
                SettingRow(title: "Spoken punctuation",
                           detail: "Say “comma”, “period”, “question mark”, “new line”, or “new paragraph”. Off, those words are typed as words.") {
                    Toggle("Spoken punctuation", isOn: binding(\.spokenPunctuation)).toggleStyle(BrandToggleStyle())
                }
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Anything else",
                           detail: "Plain-language preferences for Polished and Refined. They never override the first rule: write what you said.")
            InstructionsEditor(text: binding(\.customInstructions), enabled: style.level.usesLanguageModel)
        }
    }

    private var engine: some View {
        let status = controller.writingStatus
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Writing engine",
                           detail: "Polished and Refined use a language model already on this Mac. Nothing is downloaded, and nothing leaves.") {
                Button("Check again", action: controller.refreshWritingStatus)
                    .buttonStyle(PillButtonStyle(kind: .text))
            }
            Panel {
                SettingRow(title: "Apple Intelligence", detail: status.appleIntelligence.detail) {
                    HStack(spacing: 8) {
                        if status.appleIntelligence == .notEnabled {
                            Button("Open Settings", action: openAppleIntelligenceSettings)
                                .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
                        }
                        EngineBadge(label: status.appleIntelligence.label, state: status.appleIntelligence == .available ? .ready
                                    : (status.appleIntelligence == .notEnabled || status.appleIntelligence == .preparing ? .attention : .absent))
                    }
                }
                RowDivider()
                SettingRow(title: "Ollama", detail: ollamaDetail(status.ollama)) {
                    if status.ollama.models.isEmpty {
                        EngineBadge(label: status.ollama.running ? "No chat models" : (status.ollama.installed ? "Not running" : "Not installed"),
                                    state: status.ollama.installed ? .attention : .absent)
                    } else {
                        BrandSelect(options: status.ollama.models.map { .init(label: $0, value: $0) },
                                    selection: Binding(get: { style.ollamaModel.flatMap { status.ollama.models.contains($0) ? $0 : nil }
                                                           ?? status.ollama.models[0] },
                                                       set: { controller.preferences.value.style.ollamaModel = $0 }),
                                    width: 200, accessibilityLabel: "Ollama model")
                    }
                }
                RowDivider()
                SettingRow(title: "Polish with", detail: engineDetail(status)) {
                    BrandSelect(options: [
                        .init(label: "Automatic", value: PolishEngineChoice.automatic),
                        .init(label: "Apple Intelligence", value: .appleIntelligence),
                        .init(label: "Ollama", value: .ollama)
                    ], selection: binding(\.engine), width: 180, accessibilityLabel: "Writing engine")
                }
            }
            Text("Every rewrite is checked against what you said. If a model adds facts, answers a question, or drops part of your message, bigvoice inserts the Clean version instead and shows you why.")
                .font(BrandFont.ui(12)).lineSpacing(3).foregroundStyle(Palette.stone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ollamaDetail(_ ollama: OllamaState) -> String {
        if !ollama.installed { return "Not found. If you use Ollama, bigvoice can reuse its chat models too." }
        if !ollama.running { return "Installed but not running. Open Ollama, then check again." }
        if ollama.models.isEmpty { return "Running, with no chat models. Embedding models can't rewrite text." }
        return "\(ollama.models.count) chat \(ollama.models.count == 1 ? "model" : "models") found on this Mac, used in place."
    }

    private func engineDetail(_ status: WritingEngineStatus) -> String {
        if let engine = status.engine(for: style) { return "Using \(engine.label). Automatic prefers Apple Intelligence, then Ollama." }
        return "Nothing available yet, so Polished and Refined fall back to Clean."
    }

    private func openAppleIntelligenceSettings() {
        for target in ["x-apple.systempreferences:com.apple.Siri-Settings.extension", "x-apple.systempreferences:"] {
            if let url = URL(string: target), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - The axis

private struct LevelPanel: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preview: StylePreview
    @Binding var level: PolishLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bricolage's weight axis tracks how much bigvoice does: a hairline for Verbatim, heavy for Refined.
    private static let weights: [CGFloat] = [330, 470, 610, 760]

    private var index: Int { PolishLevel.allCases.firstIndex(of: level) ?? 0 }
    private var engine: WritingEngine? { controller.writingEngine }

    private var readout: String {
        switch level {
        case .verbatim: return "AS HEARD · NO CHANGES"
        case .clean: return "RULES ONLY · INSTANT"
        case .polished, .refined:
            guard let engine else { return "FALLS BACK TO CLEAN" }
            let time = preview.measuredMilliseconds.map { " · ≈\($0) MS" } ?? ""
            return engine.label.uppercased() + time
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ZStack(alignment: .leading) {
                        Text(level.title)
                            .font(BrandFont.display(34, weight: Self.weights[index], width: 90))
                            .tracking(-1.1)
                            .foregroundStyle(Palette.paper)
                            .id(level)
                            .transition(reduceMotion ? .opacity : .titleSwap)
                    }
                    Spacer(minLength: 8)
                    MonoLabel(text: readout, color: level.usesLanguageModel && engine == nil ? Palette.caution : Palette.stone)
                        .contentTransition(.opacity)
                }
                ZStack(alignment: .topLeading) {
                    Text(level.summary)
                        .font(BrandFont.ui(14.5))
                        .foregroundStyle(Palette.stone)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(level)
                        .transition(.crossfade)
                }
            }
            .animation(reduceMotion ? Motion.reduced : Motion.swell, value: level)
            LevelTrack(level: $level)
            if level.usesLanguageModel && engine == nil {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.caution).padding(.top, 2)
                    Text("\(controller.writingStatus.unavailableReason(for: controller.preferences.value.style)), so \(level.title) delivers Clean text for now. See Writing engine below.")
                        .font(BrandFont.ui(12.5)).foregroundStyle(Palette.paper)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.pageSwap)
            }
        }
        .padding(26)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.char))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Palette.line(0.08), lineWidth: 1))
        .animation(reduceMotion ? Motion.reduced : Motion.settle, value: level.usesLanguageModel && engine == nil)
    }
}

/// Four stops on one line. Drag or click anywhere; the level changes as you cross each stop, so the specimens
/// below morph while you move. Arrow keys and VoiceOver adjust it one stop at a time.
private struct LevelTrack: View {
    @Binding var level: PolishLevel
    @State private var dragX: CGFloat?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let levels = PolishLevel.allCases
    private let knob: CGFloat = 22
    private let captions = ["Every um, as heard", "No ums, instant", "Your words, corrected", "Ready to send"]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let inset = knob / 2
            let step = (width - knob) / CGFloat(levels.count - 1)
            let selected = CGFloat(levels.firstIndex(of: level) ?? 0)
            let x = dragX ?? inset + step * selected
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.line(0.1))
                    .frame(width: width - knob, height: 4)
                    .offset(x: inset, y: 9)
                Capsule().fill(Palette.signal)
                    .frame(width: max(0.01, x - inset), height: 4)
                    .offset(x: inset, y: 9)
                ForEach(levels.indices, id: \.self) { i in
                    let stop = inset + step * CGFloat(i)
                    let reached = stop <= x + 0.5
                    Circle().fill(reached ? Palette.signal : Palette.surface)
                        .overlay(Circle().strokeBorder(reached ? Palette.signal : Palette.line(0.24), lineWidth: 1))
                        .frame(width: 10, height: 10)
                        .offset(x: stop - 5, y: 6)
                }
                Circle().fill(Palette.paper)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(Palette.signal, lineWidth: 2).padding(-4).opacity(focused ? 1 : 0))
                    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 2)
                    .offset(x: x - inset)
                ForEach(levels.indices, id: \.self) { i in
                    label(i)
                        .frame(width: 150, alignment: i == 0 ? .leading : (i == levels.count - 1 ? .trailing : .center))
                        .offset(x: i == 0 ? 0 : (i == levels.count - 1 ? width - 150 : inset + step * CGFloat(i) - 75), y: 36)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let clamped = min(max(value.location.x, inset), width - inset)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { dragX = clamped }
                    let nearest = levels[Int(((clamped - inset) / step).rounded())]
                    if nearest != level { level = nearest }
                }
                .onEnded { _ in
                    withAnimation(reduceMotion ? Motion.reduced : Motion.settle) { dragX = nil }
                })
        }
        .frame(height: 78)
        .animation(reduceMotion ? Motion.reduced : Motion.swell, value: level)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Polish level")
        .accessibilityValue("\(level.title). \(level.summary)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
    }

    private func label(_ i: Int) -> some View {
        let active = levels[i] == level
        return VStack(alignment: i == 0 ? .leading : (i == levels.count - 1 ? .trailing : .center), spacing: 3) {
            Text(levels[i].title)
                .font(BrandFont.ui(13, weight: active ? 600 : 500))
                .foregroundStyle(active ? Palette.paper : Palette.stone)
            Text(captions[i])
                .font(BrandFont.ui(11.5))
                .foregroundStyle(Palette.stone)
        }
        .animation(Motion.fade, value: active)
    }

    private func move(_ delta: Int) {
        let index = (levels.firstIndex(of: level) ?? 0) + delta
        guard levels.indices.contains(index) else { return }
        level = levels[index]
    }
}

// MARK: - Specimens

private struct ContextCard: View {
    let context: WritingContext
    let style: StylePreferences
    let outcome: PolishOutcome?
    let pending: Bool
    @Binding var tone: WritingTone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.title).font(BrandFont.ui(14, weight: 600)).foregroundStyle(Palette.paper)
                    Text(context.examples).font(BrandFont.ui(12)).foregroundStyle(Palette.stone)
                        .lineLimit(1).truncationMode(.tail)
                }
                .layoutPriority(-1)
                Spacer(minLength: 8)
                ToneSwitch(selection: $tone, name: context.title)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VoiceMark(size: 13, state: .listen, color: Palette.stone, isStatic: true).padding(.top, 2)
                    HeardLine(tokens: heardTokens)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Heard: \(outcome?.heard ?? StylePreview.samples[context] ?? "")")
                HStack(alignment: .top, spacing: 12) {
                    VoiceMark(size: 13, state: .caret, color: Palette.signal, isStatic: true).padding(.top, 3)
                    WrittenLine(text: outcome?.text ?? "", pending: pending)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Written: \(outcome?.text ?? "")")
            }
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.char))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.line(0.08), lineWidth: 1))
    }

    /// Words the rules removed, plus any the model left out, are struck through.
    private var heardTokens: [CleanToken] {
        let sample = StylePreview.samples[context] ?? ""
        let tokens = TranscriptCleaner.annotate(sample, options: CleanerOptions(style: style, context: context, english: true))
        guard let outcome, outcome.applied.usesLanguageModel else { return tokens }
        return WordDiff.markDropped(tokens, keeping: outcome.text)
    }

    @ViewBuilder private var footer: some View {
        if pending {
            MonoLabel(text: "POLISHING ON THIS MAC", size: 10.5)
        } else if let outcome {
            if let note = outcome.note, outcome.applied < outcome.requested {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Palette.caution).frame(width: 6, height: 6).padding(.top, 5)
                    Text("\(outcome.applied.title) used. \(String(note.prefix(1)).uppercased() + String(note.dropFirst())).")
                        .font(BrandFont.ui(12)).foregroundStyle(Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let time = outcome.applied.usesLanguageModel ? " · \(outcome.milliseconds) MS" : ""
                MonoLabel(text: "\(outcome.summary.uppercased())\(time)", size: 10.5)
            }
        }
    }
}

private struct ToneSwitch: View {
    @Binding var selection: WritingTone
    let name: String
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WritingTone.allCases, id: \.self) { tone in
                ToneSegment(tone: tone, selected: tone == selection, namespace: namespace) { selection = tone }
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.ink))
        .overlay(Capsule().strokeBorder(Palette.line(0.1)))
        .fixedSize()
        .animation(reduceMotion ? Motion.reduced : Motion.settle, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) tone")
    }
}

private struct ToneSegment: View {
    let tone: WritingTone
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(tone.title)
                .font(BrandFont.ui(12, weight: selected ? 600 : 500))
                .foregroundStyle(selected || hovering ? Palette.paper : Palette.stone)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    if selected {
                        Capsule().fill(Palette.surface)
                            .overlay(Capsule().strokeBorder(Palette.line(0.14)))
                            .matchedGeometryEffect(id: "tone", in: namespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .help(tone.summary)
        .accessibilityLabel(tone.title)
        .accessibilityHint(tone.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What the speech model heard. A strike draws across each removed word, left to right, on Swell.
private struct HeardLine: View {
    let tokens: [CleanToken]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let words = tokens.filter { $0.role != .lineBreak }
        FlowLayout(spacing: 5, lineSpacing: 3) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, token in
                Text(token.text)
                    .font(BrandFont.ui(13))
                    .foregroundStyle(Palette.stone.opacity(token.removed ? 0.55 : 1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Palette.stone)
                            .frame(height: 1.2)
                            .scaleEffect(x: token.removed ? 1 : 0.001, anchor: .leading)
                            .opacity(token.removed ? 0.9 : 0)
                            .animation(reduceMotion ? Motion.reduced : Motion.swell(stagger: index % 12), value: token.removed)
                    }
                    .animation(Motion.fade, value: token.removed)
            }
        }
    }
}

/// What lands in the app. Changed words re-land individually; while a model works, a slow highlight
/// travels across the current words (motion only while something is working).
private struct WrittenLine: View {
    let text: String
    let pending: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        let words = text.split(whereSeparator: \.isWhitespace).enumerated()
            .map { WordItem(id: "\($0.offset)|\($0.element)", index: $0.offset, word: String($0.element)) }
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !pending || reduceMotion || staticRendering)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            FlowLayout(spacing: 5.5, lineSpacing: 3) {
                ForEach(words) { item in
                    Text(item.word)
                        .font(BrandFont.ui(15.5, weight: 450))
                        .foregroundStyle(Palette.paper)
                        .opacity(pending ? shimmer(item.index, count: words.count, t: t) : 1)
                        .transition(reduceMotion ? .opacity
                                    : .wordArrival.animation(Motion.swell.delay(Double(min(item.index, 18)) * 0.028)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(reduceMotion ? Motion.reduced : Motion.swell, value: text)
        .animation(Motion.fade, value: pending)
    }

    private func shimmer(_ index: Int, count: Int, t: TimeInterval) -> Double {
        guard !reduceMotion && !staticRendering else { return 0.55 }
        let front = (t * 0.55).truncatingRemainder(dividingBy: 1.4) - 0.2
        let d = Double(index) / Double(max(1, count)) - front
        return 0.42 + 0.58 * exp(-d * d * 30)
    }
}

private struct WordItem: Identifiable {
    let id: String
    let index: Int
    let word: String
}

/// Marks heard words a model dropped, by longest common subsequence over normalized words.
enum WordDiff {
    static func markDropped(_ tokens: [CleanToken], keeping text: String) -> [CleanToken] {
        let kept = tokens.indices.filter { tokens[$0].role == .word }
        let a = kept.map { normalize(tokens[$0].text) }
        let b = text.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
        guard !a.isEmpty, !b.isEmpty else { return tokens }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var matched = Set<Int>()
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { matched.insert(i); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        var result = tokens
        for (position, index) in kept.enumerated() where !matched.contains(position) {
            result[index].role = .corrected
        }
        return result
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
    }
}

// MARK: - Words and instructions

private struct VocabularyEditor: View {
    @ObservedObject var controller: AppController
    @State private var term = ""
    @State private var heard = ""
    @FocusState private var field: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Field { case term, heard }

    var body: some View {
        let words = controller.preferences.value.style.vocabulary
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                BrandField(placeholder: "Word or name", text: $term)
                    .focused($field, equals: .term)
                    .onSubmit(add)
                BrandField(placeholder: "Heard as (optional)", text: $heard)
                    .focused($field, equals: .heard)
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if words.isEmpty {
                Text("Nothing here yet. Try your name, your team's product, or an acronym you say often.")
                    .font(BrandFont.ui(12.5)).foregroundStyle(Palette.stone)
                    .transition(.crossfade)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(words) { entry in
                        WordChip(entry: entry) { controller.removeVocabulary(entry) }
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .wordArrival, removal: .crossfade))
                    }
                }
            }
        }
        .padding(18)
        .animation(reduceMotion ? Motion.reduced : Motion.swell, value: words)
    }

    private func add() {
        guard controller.addVocabulary(term: term, heardAs: heard) else { return }
        term = ""
        heard = ""
        field = .term
    }
}

private struct WordChip: View {
    let entry: VocabularyTerm
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.term).font(BrandFont.ui(13, weight: 500)).foregroundStyle(Palette.paper)
            if !entry.heardAs.isEmpty {
                Text("heard as \(entry.heardAs.joined(separator: ", "))")
                    .font(BrandFont.ui(11.5)).foregroundStyle(Palette.stone).lineLimit(1)
            }
            Button(action: remove) {
                BrandIcon(glyph: .close, on: hovering, size: 11, color: hovering ? Palette.paper : Palette.stone)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.term)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().strokeBorder(hovering ? Palette.line(0.2) : Palette.line(0.1)))
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
    }
}

private struct BrandField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.stone))
            .textFieldStyle(.plain)
            .font(BrandFont.ui(13))
            .foregroundStyle(Palette.paper)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line(0.1)))
            .accessibilityLabel(placeholder)
    }
}

private struct InstructionsEditor: View {
    @Binding var text: String
    let enabled: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Use British spelling. Never use exclamation marks. Write numbers as digits.")
                        .font(BrandFont.ui(13.5))
                        .foregroundStyle(Palette.stone)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { text },
                                         set: { text = String($0.prefix(StylePreferences.maximumInstructionLength)) }))
                    .font(BrandFont.ui(13.5))
                    .foregroundStyle(Palette.paper)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .focused($focused)
                    .accessibilityLabel("Instructions for Polished and Refined")
            }
            .frame(minHeight: 92)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.char))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? Palette.line(0.26) : Palette.line(0.08), lineWidth: 1))
            .animation(Motion.fade, value: focused)
            HStack {
                Text(enabled ? "Used by \(PolishLevel.polished.title) and \(PolishLevel.refined.title)." : "Takes effect at Polished or Refined.")
                    .font(BrandFont.ui(12)).foregroundStyle(Palette.stone)
                Spacer()
                MonoLabel(text: "\(text.count) / \(StylePreferences.maximumInstructionLength)")
            }
        }
    }
}

private struct EngineBadge: View {
    enum State { case ready, attention, absent }
    let label: String
    let state: State

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state == .ready ? Palette.signal : (state == .attention ? Palette.caution : Palette.stone.opacity(0.6)))
                .frame(width: 7, height: 7)
            Text(label).font(BrandFont.ui(12, weight: 500)).foregroundStyle(Palette.stone)
        }
        .padding(.vertical, 7)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .background(Capsule().fill(Palette.line(0.05)))
        .overlay(Capsule().strokeBorder(Palette.line(0.08)))
        .accessibilityElement(children: .combine)
    }
}
