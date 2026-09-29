import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

public struct KeyShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var display: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyLabel)
        return parts.joined(separator: " ")
    }

    public var isValid: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty &&
            modifiers.rawValue & ~UInt32(15) == 0 &&
            keyCode <= 126 && keyCode != 53 && !(54...63).contains(keyCode) &&
            !keyLabel.isEmpty && keyLabel.count <= 24
    }

    public func hasSameBinding(as other: KeyShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    public static let pushToTalk = Self(keyCode: 49, modifiers: [.control, .option], keyLabel: "Space")
    public static let handsFree = Self(keyCode: 36, modifiers: [.control, .option], keyLabel: "Return")
}

public enum ShortcutValidationError: LocalizedError {
    case invalid, duplicate
    public var errorDescription: String? {
        switch self {
        case .invalid: return "Use a key with Control, Option, or Command. Escape is reserved for cancelling dictation."
        case .duplicate: return "Push-to-talk and hands-free need different shortcuts."
        }
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var selectedModelPath: String?
    public var inputDeviceUID = "system"
    public var pushToTalk = KeyShortcut.pushToTalk
    public var handsFree = KeyShortcut.handsFree
    public var autoSend = false
    public var startSound = true
    public var stopSound = true
    public var restoreClipboard = true
    public var language = "auto"
    public var searchFolders: [String] = []
    public var modelFiles: [String] = []
    public var style = StylePreferences()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case selectedModelPath, inputDeviceUID, pushToTalk, handsFree, autoSend, startSound, stopSound
        case restoreClipboard, language, searchFolders, modelFiles, style
    }

    /// Settings saved by an older build lack newer keys. Missing values take their defaults so an
    /// upgrade never resets shortcuts or the chosen model.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedModelPath = try container.decodeIfPresent(String.self, forKey: .selectedModelPath)
        inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? inputDeviceUID
        pushToTalk = try container.decodeIfPresent(KeyShortcut.self, forKey: .pushToTalk) ?? pushToTalk
        handsFree = try container.decodeIfPresent(KeyShortcut.self, forKey: .handsFree) ?? handsFree
        autoSend = try container.decodeIfPresent(Bool.self, forKey: .autoSend) ?? autoSend
        startSound = try container.decodeIfPresent(Bool.self, forKey: .startSound) ?? startSound
        stopSound = try container.decodeIfPresent(Bool.self, forKey: .stopSound) ?? stopSound
        restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? restoreClipboard
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? language
        searchFolders = try container.decodeIfPresent([String].self, forKey: .searchFolders) ?? searchFolders
        modelFiles = try container.decodeIfPresent([String].self, forKey: .modelFiles) ?? modelFiles
        style = (try? container.decodeIfPresent(StylePreferences.self, forKey: .style)) ?? StylePreferences()
    }

    public func validateShortcuts() throws {
        guard pushToTalk.isValid, handsFree.isValid else { throw ShortcutValidationError.invalid }
        guard !pushToTalk.hasSameBinding(as: handsFree) else { throw ShortcutValidationError.duplicate }
    }
}
