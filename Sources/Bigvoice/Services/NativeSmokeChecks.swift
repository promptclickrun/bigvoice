#if DEBUG
import AppKit
import BigvoiceCore
import Carbon
import Foundation

@MainActor
enum NativeSmokeChecks {
    static func run() async throws {
        let devices = AudioDevices()
        if let error = devices.error { throw CheckFailure(message: error) }
        print("PASS Core Audio enumeration (\(devices.devices.count) input devices)")

        try TextDelivery.checkClipboardRoundTrip()
        print("PASS Private pasteboard preserves text and binary representations")

        let manager = HotkeyManager()
        defer { manager.suspend() }
        var preferences = Preferences()
        preferences.pushToTalk = KeyShortcut(keyCode: 79, modifiers: [.command, .control, .option, .shift], keyLabel: "F18")
        preferences.handsFree = KeyShortcut(keyCode: 80, modifiers: [.command, .control, .option, .shift], keyLabel: "F19")
        var actions: [HotkeyAction] = []
        manager.onAction = { actions.append($0) }
        try manager.configure(preferences)
        try sendHotkey(id: 1, pressed: true)
        try sendHotkey(id: 1, pressed: true)
        try sendHotkey(id: 1, pressed: false)
        try sendHotkey(id: 2, pressed: true)
        try sendHotkey(id: 2, pressed: false)
        try await Task.sleep(for: .milliseconds(60))
        guard actions == [.pushDown, .pushUp, .toggleHandsFree] else {
            throw CheckFailure(message: "Native hotkey dispatch or repeat suppression failed.")
        }
        manager.suspend()
        try sendHotkey(id: 1, pressed: true)
        try await Task.sleep(for: .milliseconds(30))
        guard actions.count == 3 else { throw CheckFailure(message: "A suspended shortcut still fired.") }
        print("PASS Carbon registration, press/release, repeat suppression, and suspension")

        let indexed = await SpotlightModelSearch().search()
        print("PASS Bounded Spotlight search (\(indexed.files.count) candidates)")
        if let warning = indexed.warning { print("Notice: \(warning)") }
        print("Native service checks passed. No microphone recording or cross-app keystrokes were performed.")
    }

    private static func sendHotkey(id: UInt32, pressed: Bool) throws {
        var event: EventRef?
        let kind = pressed ? kEventHotKeyPressed : kEventHotKeyReleased
        let creation = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind),
                                   GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &event)
        guard creation == noErr, let event else { throw CheckFailure(message: "Could not create an internal Carbon event.") }
        defer { ReleaseEvent(event) }
        var identifier = EventHotKeyID(signature: 0x42564743, id: id)
        let parameter = SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &identifier
        )
        guard parameter == noErr else { throw CheckFailure(message: "Could not populate an internal Carbon event.") }
        let delivery = SendEventToEventTarget(event, GetApplicationEventTarget())
        guard delivery == noErr else { throw CheckFailure(message: "Internal hotkey event was not handled (\(delivery)).") }
    }

    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
#endif
