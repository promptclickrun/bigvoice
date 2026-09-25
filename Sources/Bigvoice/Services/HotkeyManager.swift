import AppKit
import BigvoiceCore
import Carbon
import Foundation

enum HotkeyAction: Equatable { case pushDown, pushUp, toggleHandsFree, cancel }

struct HotkeyError: LocalizedError {
    let shortcut: String
    let status: OSStatus
    var errorDescription: String? {
        "\(shortcut) could not be registered (error \(status)). It may be used by macOS or another app. Choose another shortcut."
    }
}

@MainActor
final class HotkeyManager {
    private var handler: EventHandlerRef?
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var held = Set<UInt32>()
    private var current: Preferences?
    var onAction: ((HotkeyAction) -> Void)?

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard result == noErr, identifier.signature == 0x42564743 else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
                let id = identifier.id
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                DispatchQueue.main.async { [weak manager] in manager?.received(id: id, pressed: pressed) }
                return noErr
            },
            types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        if status != noErr { handler = nil }
    }

    deinit {
        for reference in registered.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func configure(_ preferences: Preferences) throws {
        try preferences.validateShortcuts()
        guard handler != nil else { throw HotkeyError(shortcut: "Global shortcuts", status: OSStatus(eventInternalErr)) }
        let old = current
        suspend()
        do {
            try register(preferences.pushToTalk, id: 1)
            try register(preferences.handsFree, id: 2)
            current = preferences
        } catch {
            suspend()
            if let old {
                do {
                    try register(old.pushToTalk, id: 1)
                    try register(old.handsFree, id: 2)
                } catch {
                    suspend()
                    throw error
                }
            }
            throw error
        }
    }

    func suspend() {
        for reference in registered.values { UnregisterEventHotKey(reference) }
        registered.removeAll()
        held.removeAll()
    }

    func enableCancel(_ enabled: Bool) throws {
        if let reference = registered.removeValue(forKey: 3) { UnregisterEventHotKey(reference) }
        held.remove(3)
        if enabled {
            try register(KeyShortcut(keyCode: 53, modifiers: [], keyLabel: "Escape"), id: 3)
        }
    }

    private func register(_ shortcut: KeyShortcut, id: UInt32) throws {
        var flags: UInt32 = 0
        if shortcut.modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, flags, EventHotKeyID(signature: 0x42564743, id: id),
            GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else { throw HotkeyError(shortcut: shortcut.display, status: status) }
        registered[id] = reference
    }

    private func received(id: UInt32, pressed: Bool) {
        guard registered[id] != nil else { return }
        if pressed {
            guard held.insert(id).inserted else { return }
            switch id {
            case 1: onAction?(.pushDown)
            case 2: onAction?(.toggleHandsFree)
            case 3: onAction?(.cancel)
            default: break
            }
        } else {
            guard held.remove(id) != nil else { return }
            if id == 1 { onAction?(.pushUp) }
        }
    }
}
