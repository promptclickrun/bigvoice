import BigvoiceCore
import SwiftUI

struct DictationView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var meter: LevelMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .center, spacing: 12) {
                StatusPill(label: controller.statusLabel, lit: controller.busy || controller.isDelivered,
                           glowing: controller.phase.isRecording)
                Spacer(minLength: 8)
                MonoLabel(text: controller.modeTag)
                    .contentTransition(.opacity)
                    .animation(Motion.fade, value: controller.modeTag)
            }
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    Text(controller.stageTitle)
                        .font(BrandFont.display(40, weight: 620, width: 90))
                        .tracking(-1.4)
                        .foregroundStyle(Palette.paper)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(controller.stageTitle)
                        .transition(reduceMotion ? .opacity : .titleSwap)
                }
                .animation(reduceMotion ? Motion.reduced : Motion.swell, value: controller.stageTitle)
                .accessibilityAddTraits(.isHeader)
                Text("Dictate into the apps you already use. Your audio stays on this Mac.")
                    .font(BrandFont.ui(15))
                    .foregroundStyle(Palette.stone)
            }
            Stage(controller: controller, meter: meter)
            if !controller.isReady && !controller.busy {
                SetupPanel(controller: controller)
                    .transition(reduceMotion ? .opacity : .pageSwap)
            }
            TwoWays(controller: controller)
            MetaRow(controller: controller)
        }
        .animation(reduceMotion ? Motion.reduced : Motion.settle, value: controller.isReady)
    }
}

// MARK: - Stage

private struct Stage: View {
    @ObservedObject var controller: AppController
    @ObservedObject var meter: LevelMeter
    @State private var copied = false
    @State private var showHeard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recording: Bool { controller.phase.isRecording }
    private var working: Bool { controller.phase == .transcribing || controller.phase == .inserting }

    private var waveMode: WaveMode {
        if recording { return .listening }
        if working { return .working }
        return .idle
    }

    /// Heard and final differ whenever cleanup or polish changed something worth comparing.
    private var canCompare: Bool {
        !controller.busy && !controller.lastHeard.isEmpty && controller.lastHeard != controller.lastTranscript
    }

    private var transcript: String {
        if controller.busy { return controller.liveTranscript }
        return showHeard && canCompare ? controller.lastHeard : controller.lastTranscript
    }

    private var transcriptLabel: String {
        if recording { return "LIVE TRANSCRIPT" }
        if controller.polishing { return "POLISHING ON THIS MAC" }
        if !controller.busy && !controller.lastTranscript.isEmpty {
            if showHeard && canCompare { return "AS HEARD · BEFORE ANY CLEANUP" }
            if let outcome = controller.lastOutcome { return "LAST DICTATION · \(outcome.summary.uppercased())" }
            return "LAST DICTATION · MEMORY ONLY"
        }
        return "TRANSCRIPT"
    }

    /// Why polish stepped back to Clean, in the product's words.
    private var fallbackNote: String? {
        guard !controller.busy, !(showHeard && canCompare), let outcome = controller.lastOutcome,
              let note = outcome.note, outcome.applied < outcome.requested else { return nil }
        return "\(outcome.applied.title) used. \(String(note.prefix(1)).uppercased() + String(note.dropFirst()))."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 22) {
                MarkDisc(controller: controller, meter: meter)
                BarWaveform(meter: meter, count: 56, gap: 3, mode: waveMode, idleOpacity: 0.35)
                    .frame(height: 64)
                Text(meter.label)
                    .font(BrandFont.mono(14, weight: 500))
                    .foregroundStyle(recording ? Palette.signal : Palette.stone)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: meter.elapsed)
                    .animation(Motion.fade, value: recording)
                    .frame(width: 48, alignment: .trailing)
                    .accessibilityLabel("Elapsed \(meter.label)")
            }
            Palette.line(0.07).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    MonoLabel(text: transcriptLabel)
                        .contentTransition(.opacity)
                        .animation(Motion.fade, value: transcriptLabel)
                    Spacer(minLength: 8)
                    if canCompare {
                        HeardFinalSwitch(showHeard: $showHeard)
                            .transition(.crossfade)
                    }
                }
                .animation(Motion.settle, value: canCompare)
                ZStack(alignment: .topLeading) {
                    Text("Your words appear here as you speak. Practice mode never pastes or sends.")
                        .font(BrandFont.ui(17))
                        .lineSpacing(9)
                        .foregroundStyle(Palette.stone)
                        .opacity(transcript.isEmpty ? 1 : 0)
                        .animation(Motion.fade, value: transcript.isEmpty)
                    TranscriptWords(text: transcript, emphasizeNewest: recording,
                                    tone: working || (showHeard && canCompare) ? Palette.stone : Palette.paper)
                }
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                if let fallbackNote {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Palette.caution).frame(width: 6, height: 6).padding(.top, 5)
                        Text(fallbackNote).font(BrandFont.ui(12.5)).foregroundStyle(Palette.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.crossfade)
                }
            }
            .animation(Motion.settle, value: fallbackNote)
            controls
        }
        .onChange(of: controller.busy) { _, busy in if busy { showHeard = false } }
        .padding(26)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.char))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(recording ? Palette.signal(0.45) : Palette.line(0.08), lineWidth: 1))
        .animation(.easeInOut(duration: 0.5), value: recording)
    }

    private var controls: some View {
        let practicing = recording || controller.phase == .arming(.practice)
        return HStack(spacing: 10) {
            HoverReader { hovering in
                Button {
                    if recording { controller.stop() } else if !controller.busy { controller.start(.practice) }
                } label: {
                    HStack(spacing: 10) {
                        BrandIcon(glyph: recording ? .stop : .mic, on: hovering && !recording, size: 18,
                                  color: Palette.ink, background: Palette.signal)
                        Text(recording ? "Finish dictation" : "Try it here")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .signal, height: 44))
            }
            .opacity(controller.busy && !recording ? 0.45 : 1)
            .disabled(controller.selectedModel == nil || controller.installation != nil || controller.preparingModelID != nil
                      || (controller.busy && !practicing && !recording))
            .animation(Motion.fade, value: controller.busy)

            ZStack(alignment: .leading) {
                if controller.busy {
                    HoverReader { hovering in
                        Button(action: controller.cancel) {
                            HStack(spacing: 8) {
                                BrandIcon(glyph: .close, on: hovering, size: 16, color: Palette.paper)
                                Text("Cancel")
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 44))
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -10)))
                } else if !controller.lastTranscript.isEmpty {
                    HoverReader { hovering in
                        Button {
                            if controller.copyTranscript(heard: showHeard && canCompare) { flashCopied() }
                        } label: {
                            HStack(spacing: 8) {
                                BrandIcon(glyph: .check, on: copied || hovering, size: 16,
                                          color: copied ? Palette.signal : Palette.paper)
                                Text(copied ? "Copied" : "Copy")
                                    .contentTransition(.opacity)
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 44))
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -10)))
                }
            }
            .animation(reduceMotion ? Motion.reduced : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45), value: controller.busy)
            Spacer(minLength: 8)
            Text("esc cancels")
                .font(BrandFont.mono(11.5, weight: 400))
                .foregroundStyle(Palette.stone)
        }
    }

    private func flashCopied() {
        withAnimation(Motion.fade) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Motion.fade) { copied = false }
        }
    }
}

/// The 76 pt stage disc: a Signal ring that swells with the live level behind the state-following mark.
private struct MarkDisc: View {
    @ObservedObject var controller: AppController
    let meter: LevelMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        let recording = controller.phase.isRecording
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !recording || reduceMotion || staticRendering)) { timeline in
                let level = recording ? meter.envelope(at: timeline.date.timeIntervalSinceReferenceDate) : 0
                Circle()
                    .fill(Palette.signal)
                    .opacity(recording ? 0.1 + level * 0.35 : 0.12)
                    .scaleEffect(1 + level * 0.4)
            }
            Circle().fill(Palette.signal(0.1))
            VoiceMark(size: 40, state: controller.markState,
                      color: controller.phase == .idle && !controller.isDelivered ? Palette.paper : Palette.signal,
                      envelope: { meter.envelope(at: $0) })
        }
        .frame(width: 76, height: 76)
    }
}

// MARK: - Setup

private struct SetupPanel: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading("Make yourself heard", detail: "Three quick steps. Each one checks itself off.")
            Panel {
                step(done: controller.selectedModel != nil, title: "Choose a local model",
                     detail: controller.selectedModel.map { "\($0.displayName) · \($0.isManaged ? "bigvoice download" : "reused from \($0.source)")" }
                         ?? "Reuse one you have, or start with a 32 MB download.",
                     action: "Choose model") { controller.page = .models }
                RowDivider()
                step(done: controller.microphoneGranted, title: "Microphone",
                     detail: "Only active while you're dictating.", action: "Allow", perform: controller.requestMicrophone)
                RowDivider()
                step(done: controller.accessibilityGranted, title: "Accessibility",
                     detail: controller.accessibilityGranted ? "Inserts your words into other apps."
                        : "Inserts your words into other apps. Already switched on in System Settings? Press Repair: macOS is remembering an earlier build.",
                     action: "Allow", perform: controller.requestAccessibility,
                     repair: controller.repairAccessibility)
            }
        }
    }

    private func step(done: Bool, title: String, detail: String, action: String, perform: @escaping () -> Void,
                      repair: (() -> Void)? = nil) -> some View {
        SettingRow(title: title, detail: detail) {
            ZStack(alignment: .trailing) {
                if done {
                    HStack(spacing: 7) {
                        VoiceMark(size: 16, state: .check, color: Palette.signal, isStatic: true)
                        Text("Done").font(BrandFont.mono(11.5, weight: 500)).foregroundStyle(Palette.signal)
                    }
                    .transition(.crossfade)
                } else {
                    HStack(spacing: 6) {
                        if let repair {
                            Button("Repair", action: repair)
                                .buttonStyle(PillButtonStyle(kind: .quiet, height: 32))
                                .help("Clear bigvoice's stale Accessibility approval, then allow it again")
                        }
                        Button(action, action: perform)
                            .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
                    }
                    .transition(.crossfade)
                }
            }
            .animation(Motion.swell, value: done)
        }
    }
}

// MARK: - Shortcuts

private struct TwoWays: View {
    @ObservedObject var controller: AppController

    var body: some View {
        let recordingMode: DictationMode? = controller.phase.isRecording ? controller.sessionMode : nil
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Two ways to get a word in", detail: nil) {
                Button("Customize") { controller.page = .settings }
                    .buttonStyle(PillButtonStyle(kind: .text))
            }
            HStack(alignment: .top, spacing: 12) {
                card(title: "Push to talk", detail: "Hold to speak. Release to insert.",
                     shortcut: controller.preferences.value.pushToTalk, active: recordingMode == .pushToTalk, presses: true)
                card(title: "Hands-free", detail: "Press once to start. Press again to finish.",
                     shortcut: controller.preferences.value.handsFree, active: recordingMode == .handsFree, presses: false)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let error = controller.shortcutError {
                Text(error).font(BrandFont.ui(12.5)).foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card(title: String, detail: String, shortcut: KeyShortcut, active: Bool, presses: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(BrandFont.ui(14, weight: 600)).foregroundStyle(Palette.paper)
                Text(detail).font(BrandFont.ui(12.5)).foregroundStyle(Palette.stone)
            }
            Keycaps(parts: shortcut.parts, pressed: active && presses)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.char))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(active ? Palette.signal(0.45) : Palette.line(0.08), lineWidth: 1))
        .animation(.easeInOut(duration: 0.4), value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(shortcut.spokenDescription). \(detail)")
    }
}

private struct MetaRow: View {
    @ObservedObject var controller: AppController

    var body: some View {
        let preferences = controller.preferences.value
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                BrandIcon(glyph: .mic, on: controller.phase.isRecording, size: 14, color: Palette.stone, background: Palette.ink)
                Text(controller.devices.name(for: preferences.inputDeviceUID))
            }
            Spacer(minLength: 8)
            HoverReader { hovering in
                Button { controller.page = .style } label: {
                    HStack(spacing: 8) {
                        BrandIcon(glyph: .style, on: hovering, size: 14, color: hovering ? Palette.paper : Palette.stone,
                                  background: Palette.ink)
                        Text(styleSummary(preferences.style))
                            .foregroundStyle(hovering ? Palette.paper : Palette.stone)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Style")
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                BrandIcon(glyph: .key, on: false, size: 14, color: Palette.stone, background: Palette.ink)
                Text(preferences.autoSend ? "Presses Return after inserting" : "You decide when to send")
            }
        }
        .font(BrandFont.ui(12.5))
        .foregroundStyle(Palette.stone)
    }

    private func styleSummary(_ style: StylePreferences) -> String {
        switch style.level {
        case .verbatim: return "Verbatim · exactly as heard"
        case .clean: return "Clean · fillers removed"
        case .polished, .refined:
            return controller.writingEngine == nil ? "\(style.level.title) · falls back to Clean" : "\(style.level.title) · tone follows the app"
        }
    }
}

/// Final and Heard, side by side in one quiet switch.
private struct HeardFinalSwitch: View {
    @Binding var showHeard: Bool

    var body: some View {
        HStack(spacing: 14) {
            ForEach([false, true], id: \.self) { heard in
                let active = showHeard == heard
                Button(heard ? "Heard" : "Final") {
                    withAnimation(Motion.settle) { showHeard = heard }
                }
                .buttonStyle(.plain)
                .font(BrandFont.ui(12, weight: active ? 600 : 500))
                .foregroundStyle(active ? Palette.paper : Palette.stone)
                .overlay(alignment: .bottom) {
                    Capsule().fill(Palette.paper).frame(height: 1.5).offset(y: 4).opacity(active ? 1 : 0)
                }
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show transcript")
    }
}
