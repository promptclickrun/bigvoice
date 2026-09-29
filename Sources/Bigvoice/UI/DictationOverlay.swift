import AppKit
import BigvoiceCore
import SwiftUI

enum CapsuleContent: Equatable {
    case arming, listening, transcribing, inserting
    case polishing(String)
    case delivered(Delivery)
    case attention(kind: AppNotice.Kind, title: String, id: UUID)

    var width: CGFloat {
        switch self {
        case .arming: return 232
        case .listening: return 372
        case .transcribing, .inserting, .delivered: return 262
        case .polishing: return 300
        case .attention: return 300
        }
    }

    var mark: MarkState {
        switch self {
        case .arming: return .dots
        case .listening: return .listen
        case .transcribing, .polishing: return .wave
        case .inserting: return .caret
        case .delivered: return .check
        case .attention: return .idle
        }
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var content: CapsuleContent?
    @Published var instruction: String?
}

enum OverlayMetrics {
    static let size = NSSize(width: 460, height: 150)
}

/// Floats above the Dock in every Space. Never takes focus. Resizes to what it has to say.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let meter: LevelMeter
    let stop: () -> Void
    let cancel: () -> Void
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            if let instruction = model.instruction, model.content != nil {
                Text(instruction)
                    .font(BrandFont.ui(11.5, weight: 500))
                    .foregroundStyle(Palette.paper)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .id(instruction)
                    .transition(reduceMotion ? .opacity : .modifier(active: Appear(opacity: 0, y: 10, scale: 1),
                                                                     identity: Appear(opacity: 1, y: 0, scale: 1)))
            }
            if let content = model.content {
                CapsuleBody(content: content, meter: meter, stop: stop, cancel: cancel, open: open)
                    .transition(reduceMotion ? .opacity : .modifier(active: Appear(opacity: 0, y: 18, scale: 0.92),
                                                                     identity: Appear(opacity: 1, y: 0, scale: 1)))
            }
        }
        .padding(.bottom, 26)
        .frame(width: OverlayMetrics.size.width, height: OverlayMetrics.size.height, alignment: .bottom)
        .environment(\.colorScheme, .dark)
    }
}

private struct Appear: ViewModifier {
    let opacity: Double
    let y: CGFloat
    let scale: CGFloat
    func body(content: Content) -> some View {
        content.opacity(opacity).scaleEffect(scale, anchor: .bottom).offset(y: y)
    }
}

private struct CapsuleBody: View {
    let content: CapsuleContent
    let meter: LevelMeter
    let stop: () -> Void
    let cancel: () -> Void
    let open: () -> Void
    @State private var hoveringStop = false
    @State private var hoveringClose = false

    private var listening: Bool { content == .listening }
    private var isPolishing: Bool { if case .polishing = content { return true }; return false }
    private var working: Bool { content == .arming || content == .transcribing || content == .inserting || isPolishing }
    private var isAttention: Bool { if case .attention = content { return true }; return false }
    private var isDelivered: Bool { if case .delivered = content { return true }; return false }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill((isAttention ? Palette.caution : Palette.signal).opacity(0.12))
                VoiceMark(size: 24, state: content.mark, color: isAttention ? Palette.caution : Palette.signal,
                          envelope: { meter.envelope(at: $0) })
            }
            .frame(width: 40, height: 40)
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 3) {
                    BarWaveform(meter: meter, count: 26, gap: 2.5, mode: listening ? .listening : .idle, idleOpacity: 1)
                        .frame(height: 24)
                    Elapsed(meter: meter)
                }
                .opacity(listening ? 1 : 0)
                layer(title: workingTitle, detail: workingDetail)
                    .opacity(working ? 1 : 0)
                layer(title: deliveredTitle, detail: deliveredDetail)
                    .opacity(isDelivered ? 1 : 0)
                layer(title: attentionTitle, detail: "Open bigvoice for details")
                    .opacity(isAttention ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.3), value: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if isAttention { open() } }
            Button(action: stop) {
                RoundedRectangle(cornerRadius: 2.5).fill(Palette.paper).frame(width: 10, height: 10)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(hoveringStop ? Palette.line(0.08) : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringStop = $0 }
            .frame(width: listening ? 32 : 0)
            .opacity(listening ? 1 : 0)
            .clipped()
            .accessibilityLabel("Finish and insert")
            Button(action: cancel) {
                BrandIcon(glyph: .close, on: hoveringClose, size: 14, color: Palette.stone)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(hoveringClose ? Palette.line(0.08) : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .frame(width: isDelivered ? 0 : 32)
            .opacity(isDelivered ? 0 : 1)
            .clipped()
            .accessibilityLabel(isAttention ? "Dismiss" : "Cancel dictation")
        }
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .frame(width: content.width, height: 62)
        .clipShape(Capsule())
        .background(Capsule().fill(Palette.char))
        .overlay(Capsule().strokeBorder(Palette.line(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("bigvoice dictation")
    }

    private func layer(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(BrandFont.ui(13, weight: 600)).foregroundStyle(Palette.paper).lineLimit(1)
            Text(detail).font(BrandFont.mono(10, weight: 400)).foregroundStyle(Palette.stone).lineLimit(1)
        }
    }

    private var workingTitle: String {
        switch content {
        case .arming: return "Getting ready"
        case .transcribing: return "Transcribing"
        case .polishing: return "Polishing"
        case .inserting: return "Inserting"
        default: return " "
        }
    }

    private var workingDetail: String {
        if case let .polishing(style) = content { return style }
        return "Entirely on your Mac"
    }

    private var deliveredTitle: String { if case let .delivered(d) = content { return d.title }; return " " }
    private var deliveredDetail: String { if case let .delivered(d) = content { return d.detail }; return " " }
    private var attentionTitle: String { if case let .attention(_, title, _) = content { return title }; return " " }
}

private struct Elapsed: View {
    @ObservedObject var meter: LevelMeter
    var body: some View {
        Text("\(meter.label) · Listening")
            .font(BrandFont.mono(10, weight: 400))
            .foregroundStyle(Palette.stone)
            .lineLimit(1)
    }
}

private final class NonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the capsule panel and follows the same single state as the sidebar mark and menu bar glyph.
@MainActor
final class DictationOverlay {
    private let panel: NSPanel
    private let controller: AppController
    private let model = OverlayModel()
    private var hideTask: Task<Void, Never>?
    private var shownNoticeID: UUID?
    private var shownDeliveryID: UUID?
    private var sessionMode: DictationMode?
    private var wasBusy = false
    var isWindowFrontmost: () -> Bool = { false }

    init(controller: AppController) {
        self.controller = controller
        panel = NonactivatingPanel(contentRect: NSRect(origin: .zero, size: OverlayMetrics.size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = OverlayView(model: model, meter: controller.meter,
                               stop: { [weak controller] in controller?.stop() },
                               cancel: { [weak self, weak controller] in
                                   if controller?.busy == true { controller?.cancel() } else { self?.hide(animated: true) }
                               },
                               open: { [weak controller] in controller?.onShowWindow?() })
        panel.contentView = OverlayHostingView(rootView: view)
        panel.setAccessibilityLabel("bigvoice dictation")
    }

    func update() {
        let phase = controller.phase
        if phase.isBusy {
            if !wasBusy { sessionMode = controller.sessionMode }
            wasBusy = true
            // Practice lives in the main window's stage.
            guard sessionMode != .practice else { return }
            let content: CapsuleContent
            switch phase {
            case .arming: content = .arming
            case .recording: content = .listening
            case .transcribing: content = controller.polishing ? .polishing(controller.sessionStyleLabel) : .transcribing
            default: content = .inserting
            }
            present(content, instruction: instruction(for: content))
            return
        }
        let endedSession = wasBusy
        wasBusy = false
        if let delivery = controller.delivered, delivery.id != shownDeliveryID {
            shownDeliveryID = delivery.id
            let practice = sessionMode == .practice
            sessionMode = nil
            if practice || isWindowFrontmost() { hide(animated: true); return }
            present(.delivered(delivery), instruction: delivery.instruction)
            return
        }
        if let notice = controller.notice, notice.origin == .dictation, notice.id != shownNoticeID {
            shownNoticeID = notice.id
            let practice = sessionMode == .practice
            sessionMode = nil
            if practice || isWindowFrontmost() { hide(animated: true); return }
            present(.attention(kind: notice.kind, title: notice.title, id: notice.id), instruction: nil)
            scheduleHide(after: notice.kind == .info ? 2.2 : 4.5)
            return
        }
        if controller.delivered == nil, case .delivered = model.content { hide(animated: true); return }
        if endedSession { hide(animated: true, hush: controller.notice == nil || controller.notice?.origin != .dictation) }
    }

    func hide(animated: Bool = false, hush: Bool = false) {
        hideTask?.cancel()
        guard model.content != nil || panel.isVisible else { return }
        let animation = hush ? Motion.hush : Motion.swell
        if animated {
            withAnimation(animation) {
                model.content = nil
                model.instruction = nil
            }
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(hush ? 0.25 : 0.6))
                guard let self, !Task.isCancelled, self.model.content == nil else { return }
                self.panel.orderOut(nil)
            }
        } else {
            model.content = nil
            model.instruction = nil
            panel.orderOut(nil)
        }
    }

    private func present(_ content: CapsuleContent, instruction: String?) {
        hideTask?.cancel()
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
        guard model.content != content || model.instruction != instruction else { return }
        withAnimation(Motion.swell) {
            model.content = content
            model.instruction = instruction
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.controller.busy else { return }
            self.hide(animated: true)
        }
    }

    private func instruction(for content: CapsuleContent) -> String {
        let preferences = controller.preferences.value
        switch content {
        case .arming: return "Opening your microphone · Esc to cancel"
        case .listening:
            return sessionMode == .handsFree
                ? "Press \(preferences.handsFree.parts.joined(separator: " ")) to finish"
                : "Release \(preferences.pushToTalk.parts.joined(separator: " ")) to finish"
        case .transcribing: return "Transcribing offline · Esc to cancel"
        case .polishing: return "Polishing on this Mac · Esc to cancel"
        case .inserting: return "Inserting into your original app"
        case .delivered(let delivery): return delivery.instruction
        case .attention: return ""
        }
    }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - OverlayMetrics.size.width / 2, y: frame.minY + 8))
    }
}

#if DEBUG
/// Snapshot helper: the capsule over the spec's desktop backdrop.
struct OverlayPreview: View {
    let content: CapsuleContent
    let instruction: String?
    let meter: LevelMeter

    var body: some View {
        let model = OverlayModel()
        model.content = content
        model.instruction = instruction
        return ZStack(alignment: .bottom) {
            Palette.desk
            OverlayView(model: model, meter: meter, stop: {}, cancel: {}, open: {})
        }
    }
}
#endif
