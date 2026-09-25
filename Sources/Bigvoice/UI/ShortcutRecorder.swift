import AppKit
import BigvoiceCore
import SwiftUI

/// Records a global shortcut. Held modifiers appear as pressed keycaps; an invalid combination
/// shakes the field; a successful capture lands with a haptic tick.
struct ShortcutRecorder: View {
    let shortcut: KeyShortcut
    let controller: AppController
    let pushToTalk: Bool
    @State private var recording = false
    @State private var held: ShortcutModifiers = []
    @State private var monitor: Any?
    @State private var error: String?
    @State private var shakes = 0
    @State private var successes = 0
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                field
            }
            .buttonStyle(.plain)
            .disabled(controller.isRecordingShortcut && !recording)
            .keyframeAnimator(initialValue: 0.0, trigger: shakes) { content, x in
                content.offset(x: x)
            } keyframes: { _ in
                CubicKeyframe(-6, duration: 0.05)
                CubicKeyframe(5, duration: 0.07)
                CubicKeyframe(-3, duration: 0.07)
                CubicKeyframe(0, duration: 0.08)
            }
            .sensoryFeedback(.levelChange, trigger: successes)
            .accessibilityLabel(recording ? "Recording shortcut. Press keys, or Escape to cancel."
                                : "\(pushToTalk ? "Push to talk" : "Hands-free") shortcut, \(shortcut.spokenDescription). Activate to change.")
            if let error {
                Text(error)
                    .font(BrandFont.ui(12))
                    .foregroundStyle(Palette.caution)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.crossfade)
            }
        }
        .animation(Motion.settle, value: error)
        .onDisappear(perform: stopRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stopRecording() }
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return ZStack(alignment: .trailing) {
            if recording {
                HStack(spacing: 8) {
                    if held.isEmpty {
                        Text("type a shortcut").font(BrandFont.mono(11.5, weight: 500)).foregroundStyle(Palette.stone)
                        Caret()
                    } else {
                        Keycaps(parts: modifierParts(held), size: .small, pressed: true)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 150, minHeight: 38, alignment: .trailing)
                .background(shape.fill(Palette.signal(0.08)))
                .overlay(shape.strokeBorder(Palette.signal(0.6), lineWidth: 1))
                .transition(.crossfade)
            } else {
                Keycaps(parts: shortcut.parts, size: .small)
                    .id(shortcut)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .background(shape.fill(hovering ? Palette.line(0.05) : Color.clear))
                    .transition(reduceMotion ? .opacity : .wordArrival)
            }
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(Motion.settle, value: recording)
        .animation(.easeOut(duration: 0.16), value: held.rawValue)
        .animation(.easeInOut(duration: 0.3), value: hovering)
    }

    private func startRecording() {
        error = nil
        held = []
        recording = true
        controller.setShortcutRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                held = modifiers(from: event.modifierFlags)
                return nil
            }
            if event.keyCode == 53 { stopRecording(); return nil }
            let captured = KeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers(from: event.modifierFlags),
                                       keyLabel: keyLabel(event))
            do {
                try controller.updateShortcut(captured, pushToTalk: pushToTalk)
                successes += 1
                stopRecording()
            } catch {
                self.error = error.localizedDescription
                if !reduceMotion { shakes += 1 }
            }
            return nil
        }
    }

    private func stopRecording() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        held = []
        controller.setShortcutRecording(false)
    }

    private func modifiers(from flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func modifierParts(_ modifiers: ShortcutModifiers) -> [String] {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        return parts
    }

    private func keyLabel(_ event: NSEvent) -> String {
        let names: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 76: "Enter",
            117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let name = names[event.keyCode] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    }
}

private struct Caret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Palette.signal)
            .frame(width: 2, height: 14)
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.15]) { view, value in
                view.opacity(value)
            } animation: { _ in .easeInOut(duration: 0.5) }
    }
}
