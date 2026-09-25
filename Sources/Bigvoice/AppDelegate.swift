import AppKit
import BigvoiceCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let controller = AppController()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var overlay: DictationOverlay?
    private var sleepObserver: NSObjectProtocol?
    private var statusTimer: Timer?
    private var statusMark: MarkState?
    private var shutdownComplete = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: 30)
        item.autosaveName = "bigvoice.status"
        item.length = 30
        item.button?.toolTip = "bigvoice · Offline dictation"
        statusItem = item
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        let overlay = DictationOverlay(controller: controller)
        overlay.isWindowFrontmost = { [weak self] in
            guard let window = self?.window else { return false }
            return NSApp.isActive && window.isVisible && window.isKeyWindow
        }
        self.overlay = overlay
        controller.onStateChange = { [weak self] in
            self?.updateStatus()
            self?.overlay?.update()
        }
        controller.onShowWindow = { [weak self] in self?.showWindow() }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.cancel() }
        }
        controller.launch()
        updateStatus()
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { controller.refreshPermissions() }

    /// ONNX Runtime must release its globals before exit, so quitting waits (briefly) for native teardown.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownComplete { return .terminateNow }
        statusTimer?.invalidate()
        overlay?.hide()
        Task { @MainActor in
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self.finishTermination()
            }
            await controller.shutdown()
            deadline.cancel()
            self.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard !shutdownComplete else { return }
        shutdownComplete = true
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1116, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "bigvoice"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // The brand is warm dark by design: "If something is orange, something is listening."
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = Palette.inkNS
            window.minSize = NSSize(width: 900, height: 660)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("bigvoice.main.v2")
            window.delegate = self
            window.contentView = NSHostingView(rootView: RootView(controller: controller))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() { controller.page = .settings; showWindow() }
    @objc private func showModels() { controller.page = .models; showWindow() }
    @objc private func toggleDictation() {
        if controller.phase.isRecording { controller.stop() } else { controller.toggleHandsFree() }
    }
    @objc private func cancelDictation() { controller.cancel() }
    @objc private func quit() { NSApp.terminate(nil) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state: String
        switch controller.phase {
        case .idle: state = controller.isReady ? "Ready" : "Needs setup"
        case .arming: state = "Opening microphone…"
        case .recording: state = "Listening…"
        case .transcribing: state = "Transcribing on this Mac…"
        case .inserting: state = "Placing words…"
        }
        let heading = NSMenuItem(title: "bigvoice · \(state)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        if let model = controller.selectedModel {
            let item = NSMenuItem(title: "\(model.name) · \(model.formatLabel)", action: #selector(showModels), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let record = NSMenuItem(title: controller.phase.isRecording ? "Finish Dictation" : "Start Hands-free Dictation",
                                action: #selector(toggleDictation), keyEquivalent: "")
        record.target = self
        record.isEnabled = controller.selectedModel != nil && (!controller.busy || controller.phase.isRecording) &&
            controller.installation == nil && controller.preparingModelID == nil
        menu.addItem(record)
        if controller.busy {
            let cancel = NSMenuItem(title: "Cancel Dictation", action: #selector(cancelDictation), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open bigvoice", action: #selector(showWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit bigvoice", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Menu bar glyph

    /// The menu bar follows the same single state as the sidebar mark and the capsule.
    private func updateStatus() {
        let state = controller.markState
        let button = statusItem?.button
        let animated = state == .listen || state == .wave
        button?.setAccessibilityLabel(controller.busy ? "bigvoice is \(controller.statusLabel.lowercased())" :
                                      (controller.isReady ? "bigvoice, ready" : "bigvoice, needs setup"))
        guard animated else {
            statusTimer?.invalidate()
            statusTimer = nil
            statusMark = state
            button?.image = StatusGlyph.image(state: state, busy: controller.busy || controller.isDelivered,
                                              ready: controller.isReady, levels: nil, time: 0)
            return
        }
        guard statusMark != state || statusTimer == nil else { return }
        statusMark = state
        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderStatusFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        renderStatusFrame()
    }

    private func renderStatusFrame() {
        let now = Date.timeIntervalSinceReferenceDate
        let envelope = controller.meter.envelope(at: now)
        statusItem?.button?.image = StatusGlyph.image(state: controller.markState, busy: true, ready: controller.isReady,
                                                      levels: envelope, time: now)
    }

    private func buildMainMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide bigvoice", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit bigvoice", action: #selector(quit), keyEquivalent: "q").target = self
        app.submenu = appMenu
        menu.addItem(app)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }
}

/// The mark at 16 pt for the menu bar. Idle is a template dot (adapts to any menu bar); while
/// sound is on, the Signal mark sits on a Signal-tinted pill, exactly as the spec's menu bar shows.
enum StatusGlyph {
    private static let signal = NSColor(hex: 0xFF8D39)

    static func image(state: MarkState, busy: Bool, ready: Bool, levels: Double?, time: TimeInterval) -> NSImage {
        let size = NSSize(width: 28, height: 22)
        let image = NSImage(size: size, flipped: true) { _ in
            if busy {
                signal.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 5, yRadius: 5).fill()
            }
            let s: CGFloat = 16
            let origin = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
            (busy ? signal : NSColor.black).setFill()
            for rect in bars(state: state, size: s, levels: levels, time: time) {
                var bar = rect
                bar.origin.x += origin.x
                bar.origin.y += origin.y
                if bar.rotation != 0 {
                    let pivot = CGPoint(x: bar.midX, y: bar.maxY - bar.width / 2)
                    let transform = NSAffineTransform()
                    transform.translateX(by: pivot.x, yBy: pivot.y)
                    transform.rotate(byDegrees: bar.rotation)
                    transform.translateX(by: -pivot.x, yBy: -pivot.y)
                    let path = NSBezierPath(roundedRect: bar.rect, xRadius: bar.width / 2, yRadius: bar.width / 2)
                    path.transform(using: transform as AffineTransform)
                    path.fill()
                } else if !ready && !busy && state == .idle {
                    NSColor.black.setStroke()
                    let ring = NSBezierPath(ovalIn: bar.rect.insetBy(dx: 0.6, dy: 0.6))
                    ring.lineWidth = 1.2
                    ring.stroke()
                } else {
                    NSBezierPath(roundedRect: bar.rect, xRadius: min(bar.width, bar.height) / 2,
                                 yRadius: min(bar.width, bar.height) / 2).fill()
                }
            }
            return true
        }
        image.isTemplate = !busy
        return image
    }

    private struct Bar {
        var rect: CGRect
        var rotation: CGFloat = 0
        var width: CGFloat { rect.width }
        var height: CGFloat { rect.height }
        var midX: CGFloat { rect.midX }
        var maxY: CGFloat { rect.maxY }
        var origin: CGPoint { get { rect.origin } set { rect.origin = newValue } }
    }

    private static func bars(state: MarkState, size s: CGFloat, levels: Double?, time t: TimeInterval) -> [Bar] {
        let w = 0.11 * s * 1.25, gap = 0.085 * s
        let x0 = (s - (5 * w + 4 * gap)) / 2
        let profile: [CGFloat] = [0.42, 0.7, 1, 0.78, 0.5]
        switch state {
        case .idle:
            let d = 0.42 * s
            return [Bar(rect: CGRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d))]
        case .listen:
            return (0..<5).map { i in
                var scale = profile[i]
                if let levels {
                    let wobble = 0.7 + 0.3 * sin(t * 8.3 + Double(i) * 1.9)
                    scale = CGFloat(max(0.12, min(1, levels * Double(profile[i]) * wobble * 1.6 + 0.1)))
                }
                let h = 0.9 * s * scale
                return Bar(rect: CGRect(x: x0 + CGFloat(i) * (w + gap), y: (s - h) / 2, width: w, height: h))
            }
        case .dots, .wave:
            return (0..<5).map { i in
                let dy = state == .wave ? CGFloat(sin(t * 7 - Double(i) * 0.8)) * s * 0.14 : 0
                return Bar(rect: CGRect(x: x0 + CGFloat(i) * (w + gap), y: (s - w) / 2 + dy, width: w, height: w))
            }
        case .caret:
            return [Bar(rect: CGRect(x: (s - w) / 2, y: 0.1 * s, width: w, height: 0.8 * s))]
        case .check:
            let vx = 0.4 * s, vy = 0.76 * s
            return [Bar(rect: CGRect(x: vx - w / 2, y: vy - 0.3 * s, width: w, height: 0.3 * s), rotation: -45),
                    Bar(rect: CGRect(x: vx - w / 2, y: vy - 0.64 * s, width: w, height: 0.64 * s), rotation: 40)]
        }
    }
}
