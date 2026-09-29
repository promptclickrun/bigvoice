import AppKit
import ApplicationServices
import BigvoiceCore
import Carbon
import Foundation
import OSLog

struct DictationDestination {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let element: AXUIElement?
    let window: AXUIElement?
    let value: String?
    let selection: NSRange?

    var context: WritingContext { WritingContext.classify(bundleIdentifier: bundleID) }

    @MainActor
    static func capture() -> DictationDestination? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let element = Accessibility.element(appElement, kAXFocusedUIElementAttribute)
        return DictationDestination(
            pid: application.processIdentifier, name: application.localizedName ?? "your app",
            bundleID: application.bundleIdentifier,
            element: element, window: Accessibility.element(appElement, kAXFocusedWindowAttribute),
            value: element.flatMap { Accessibility.string($0, kAXValueAttribute) },
            selection: element.flatMap(Accessibility.selection)
        )
    }

    @MainActor
    var stillFocused: Bool {
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        let focused = Accessibility.element(app, kAXFocusedUIElementAttribute)
        let matches = element.map { original in focused.map { CFEqual(original, $0) } ?? false } ?? true
        let currentWindow = Accessibility.element(app, kAXFocusedWindowAttribute)
        let windowMatches = window.map { original in currentWindow.map { CFEqual(original, $0) } ?? false } ?? true
        let secureField = focused.flatMap { Accessibility.string($0, kAXSubroleAttribute) } == kAXSecureTextFieldSubrole
        return windowMatches && DeliverySafety.mayDeliver(
            originalPID: pid, currentPID: currentPID, originalElementPresent: element != nil,
            focusedElementMatches: matches, secureInput: IsSecureEventInputEnabled() || secureField
        )
    }

    func expectedValue(inserting text: String) -> String? {
        DeliverySafety.expectedValue(original: value, selection: selection, inserting: text)
    }
}

enum Accessibility {
    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func selection(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

enum DeliveryError: LocalizedError {
    case permission, clipboardRead, clipboardWrite, keyboard
    var errorDescription: String? {
        switch self {
        case .permission: return "Accessibility access is required to insert text into another app. Your transcript is still available to copy."
        case .clipboardRead: return "The current clipboard could not be preserved safely. Your transcript is available to copy instead."
        case .clipboardWrite: return "macOS could not write to the clipboard. Your transcript is still available in bigvoice."
        case .keyboard: return "macOS could not create a paste event. Copy the transcript from bigvoice."
        }
    }
}

struct DeliveryResult {
    let message: String
    let needsAttention: Bool
    var sent = false
}

private struct ClipboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]

    @MainActor
    init(_ pasteboard: NSPasteboard) throws {
        var result: [[(NSPasteboard.PasteboardType, Data)]] = []
        var size = 0
        if pasteboard.pasteboardItems == nil, !(pasteboard.types ?? []).isEmpty {
            throw DeliveryError.clipboardRead
        }
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { throw DeliveryError.clipboardRead }
                size += data.count
                guard size <= 32 * 1_024 * 1_024 else { throw DeliveryError.clipboardRead }
                representations.append((type, data))
            }
            result.append(representations)
        }
        items = result
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) -> Bool {
        let restored = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}

@MainActor
final class TextDelivery {
    private var pendingRestore: (snapshot: ClipboardSnapshot, changeCount: Int)?
    private var restoreTask: Task<Void, Never>?
    var onWarning: ((String) -> Void)?

    #if DEBUG
    static func checkClipboardRoundTrip() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.bigvoice.test.binary")
        let original = NSPasteboardItem()
        original.setString("Original clipboard 🌿", forType: .string)
        original.setData(Data([0, 1, 2, 255]), forType: custom)
        guard pasteboard.writeObjects([original]) else { throw DeliveryError.clipboardWrite }
        let snapshot = try ClipboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Temporary dictation", forType: .string)
        guard snapshot.restore(to: pasteboard),
              pasteboard.string(forType: .string) == "Original clipboard 🌿",
              pasteboard.data(forType: custom) == Data([0, 1, 2, 255]) else { throw DeliveryError.clipboardRead }
    }
    #endif

    func deliver(_ text: String, to destination: DictationDestination,
                 autoSend: Bool, restoreClipboard: Bool) async throws -> DeliveryResult {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw DeliveryError.permission }
        guard destination.stillFocused else {
            return DeliveryResult(message: "Focus changed or secure input is active. Nothing was inserted. Copy your text below.", needsAttention: true)
        }
        // Don't insert at a stale cursor if the user edited the original field while speaking.
        if let element = destination.element {
            if let originalValue = destination.value,
               Accessibility.string(element, kAXValueAttribute) != originalValue {
                return DeliveryResult(message: "The text field changed while you dictated. Nothing was inserted. Your text is ready to copy.", needsAttention: true)
            }
            if let selection = destination.selection, Accessibility.selection(element) != selection {
                return DeliveryResult(message: "The cursor moved while you dictated. Nothing was inserted. Your text is ready to copy.", needsAttention: true)
            }
        }

        restorePendingClipboard()
        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboard ? try ClipboardSnapshot(pasteboard) : nil
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            if let snapshot { _ = snapshot.restore(to: pasteboard) }
            throw DeliveryError.clipboardWrite
        }
        if let snapshot {
            pendingRestore = (snapshot, pasteboard.changeCount)
        }
        defer { scheduleClipboardRestoration() }
        try Task.checkCancellation()
        guard destination.stillFocused else {
            return DeliveryResult(message: "Focus changed before pasting. Your text is ready to copy.", needsAttention: true)
        }
        try postKey(9, flags: .maskCommand, to: destination.pid)

        let expectedValue = destination.expectedValue(inserting: text)
        var confirmed = false
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(100))
            guard destination.stillFocused else { break }
            if let element = destination.element, let expectedValue,
               Accessibility.string(element, kAXValueAttribute) == expectedValue {
                confirmed = true
                break
            }
        }
        try Task.checkCancellation()
        if DeliverySafety.maySend(
            autoSend: autoSend, insertionConfirmed: confirmed,
            focusStillMatches: destination.stillFocused, cancelled: Task.isCancelled
        ) {
            try postKey(36, flags: [], to: destination.pid)
            return DeliveryResult(message: "Inserted in \(destination.name) and pressed Return.", needsAttention: false, sent: true)
        }
        if autoSend && !confirmed {
            return DeliveryResult(
                message: "Paste requested in \(destination.name). Return was not pressed because insertion could not be confirmed.",
                needsAttention: true
            )
        }
        if !destination.stillFocused {
            return DeliveryResult(message: "Focus changed after pasting. Check \(destination.name); Return was not pressed.", needsAttention: true)
        }
        return DeliveryResult(
            message: confirmed ? "Inserted in \(destination.name)." : "Paste requested in \(destination.name). If the app did not accept it, copy your text below.",
            needsAttention: !confirmed
        )
    }

    func restorePendingClipboard() {
        restoreTask?.cancel()
        restoreTask = nil
        guard let pendingRestore else { return }
        self.pendingRestore = nil
        let pasteboard = NSPasteboard.general
        guard DeliverySafety.shouldRestoreClipboard(
            ownedChangeCount: pendingRestore.changeCount, currentChangeCount: pasteboard.changeCount
        ) else { return }
        if !pendingRestore.snapshot.restore(to: pasteboard) {
            Logger.app.error("Clipboard restoration failed")
            onWarning?("The previous clipboard could not be restored.")
        }
    }

    private func scheduleClipboardRestoration() {
        guard pendingRestore != nil else { return }
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            self?.restorePendingClipboard()
        }
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags, to pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw DeliveryError.keyboard
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }
}
