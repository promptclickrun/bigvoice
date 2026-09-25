import AppKit
import BigvoiceCore
import CoreText
import SwiftUI

/*
 bigvoice brand & interface system, V2 · 2026 (provided design, implemented natively).
 Warm dark. One loud color: if something is orange, something is listening.
 Display: Bricolage Grotesque, whose weight axis tracks loudness. Interface: Geist.
 Data (shortcuts, timers, sizes): Geist Mono. Motion: Swell, Settle, Hush; three curves, no bounce.
 One mark for every state: dot → five live bars → travelling dots → caret → check.
 */

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// sRGB conversions of the spec's oklch tokens. Every text pairing measures ≥ 6.7:1.
enum Palette {
    static let ink = Color(hex: 0x0E0C0A)        // oklch .155 .006 60 — canvas
    static let menubar = Color(hex: 0x070504)    // oklch .12 .005 60
    static let char = Color(hex: 0x181513)       // oklch .20 .007 60 — sidebar, capsule, cards
    static let desk = Color(hex: 0x161311)       // oklch .19 .007 60
    static let surface = Color(hex: 0x211D1A)    // oklch .235 .008 60 — keys, raised fields
    static let stone = Color(hex: 0xAAA39D)      // oklch .72 .012 70 — secondary text
    static let paper = Color(hex: 0xF6F3EE)      // oklch .965 .008 80 — primary text
    static let signal = Color(hex: 0xFF8D39)     // oklch .76 .17 52 — sound is on
    static let caution = Color(hex: 0xEEC55E)    // oklch .84 .13 88 — warnings only

    /// The spec's warm hairline: rgba(255, 240, 220, alpha).
    static func line(_ alpha: Double) -> Color {
        Color(.sRGB, red: 1, green: 240.0 / 255, blue: 220.0 / 255, opacity: alpha)
    }

    static func signal(_ alpha: Double) -> Color { signal.opacity(alpha) }

    static let inkNS = NSColor(hex: 0x0E0C0A)
}

// MARK: - Type

enum FontRegistry {
    private static let lock = NSLock()
    private static var registered = false
    static let files = ["BricolageGrotesque-Variable.ttf", "Geist-Variable.ttf", "GeistMono-Variable.ttf"]

    static func registerIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        guard let directory = fontDirectory() else { return }
        for name in files {
            CTFontManagerRegisterFontsForURL(directory.appendingPathComponent(name) as CFURL, .process, nil)
        }
    }

    private static func fontDirectory() -> URL? {
        let manager = FileManager.default
        func hasFonts(_ url: URL) -> Bool { manager.fileExists(atPath: url.appendingPathComponent(files[0]).path) }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("Fonts"), hasFonts(resources) { return resources }
        var directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<7 {
            guard let current = directory else { break }
            let candidate = current.appendingPathComponent("Resources/Fonts")
            if hasFonts(candidate) { return candidate }
            directory = current.deletingLastPathComponent()
        }
        let local = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent("Resources/Fonts")
        return hasFonts(local) ? local : nil
    }
}

/// Variable-axis access to the brand faces, cached; falls back to SF if a face is unavailable.
enum BrandFont {
    private static let weightAxis = 0x77676874, widthAxis = 0x77647468, opticalAxis = 0x6F70737A
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CTFont] = [:]

    /// Bricolage Grotesque. `width` is the CSS font-stretch percentage (the wdth axis).
    static func display(_ size: CGFloat, weight: CGFloat = 620, width: CGFloat = 90) -> Font {
        font("Bricolage Grotesque", size: size,
             axes: [weightAxis: weight, widthAxis: width, opticalAxis: min(96, max(12, size))],
             fallback: .system(size: size, weight: .bold))
    }

    /// Geist, for interface text.
    static func ui(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        font("Geist", size: size, axes: [weightAxis: weight], fallback: .system(size: size, weight: systemWeight(weight)))
    }

    /// Geist Mono, for shortcuts, timers, and file sizes.
    static func mono(_ size: CGFloat, weight: CGFloat = 500) -> Font {
        font("Geist Mono", size: size, axes: [weightAxis: weight],
             fallback: .system(size: size, weight: systemWeight(weight), design: .monospaced))
    }

    static func ctDisplay(_ size: CGFloat, weight: CGFloat, width: CGFloat) -> CTFont? {
        ctFont("Bricolage Grotesque", size: size, axes: [weightAxis: weight, widthAxis: width, opticalAxis: min(96, max(12, size))])
    }

    private static func font(_ family: String, size: CGFloat, axes: [Int: CGFloat], fallback: Font) -> Font {
        guard let font = ctFont(family, size: size, axes: axes) else { return fallback }
        return Font(font)
    }

    private static func ctFont(_ family: String, size: CGFloat, axes: [Int: CGFloat]) -> CTFont? {
        FontRegistry.registerIfNeeded()
        let key = "\(family)|\(size)|" + axes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let variations = Dictionary(uniqueKeysWithValues: axes.map { (NSNumber(value: $0.key), NSNumber(value: Double($0.value))) })
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
            kCTFontVariationAttribute: variations
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        guard (CTFontCopyFamilyName(font) as String) == family else { return nil }
        cache[key] = font
        return font
    }

    private static func systemWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }
}

// MARK: - Motion

/// Three curves, no bounce. Fast in, soft landing.
enum Motion {
    /// 560 ms · (.2, .8, .2, 1) · stagger 28 ms — the mark and state changes.
    static let swell = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.56)
    /// 340 ms · (.3, .7, .4, 1) — pages, panels, toggles.
    static let settle = Animation.timingCurve(0.3, 0.7, 0.4, 1, duration: 0.34)
    /// 180 ms · (.4, 0, 1, 1) — cancel, dismiss, Esc.
    static let hush = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.18)
    /// The spec's `ease .3s` for color and opacity changes.
    static let fade = Animation.easeInOut(duration: 0.3)
    static let reduced = Animation.easeOut(duration: 0.15)

    static func swell(stagger index: Int) -> Animation { swell.delay(Double(index) * 0.028) }
    static let glyph = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)
}

private struct StaticRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Snapshot renders show settled end states instead of mid-flight animation.
    var staticRendering: Bool {
        get { self[StaticRenderingKey.self] }
        set { self[StaticRenderingKey.self] = newValue }
    }
}

private struct Arrival: ViewModifier {
    let blur: CGFloat
    let rise: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: blur).offset(y: rise).opacity(opacity)
    }
}

extension AnyTransition {
    /// Titles: opacity and a 10 px focus pull, rising 10 px (spec: .45 s ease, transform on Swell).
    static var titleSwap: AnyTransition {
        .modifier(active: Arrival(blur: 10, rise: 10, opacity: 0), identity: Arrival(blur: 0, rise: 0, opacity: 1))
    }
    /// Words landing in the transcript: 6 px blur, rising 8 px.
    static var wordArrival: AnyTransition {
        .modifier(active: Arrival(blur: 6, rise: 8, opacity: 0), identity: Arrival(blur: 0, rise: 0, opacity: 1))
    }
    /// Pages and panels: opacity with a 14 px rise, on Settle.
    static var pageSwap: AnyTransition {
        .modifier(active: Arrival(blur: 0, rise: 14, opacity: 0), identity: Arrival(blur: 0, rise: 0, opacity: 1))
    }
    static var crossfade: AnyTransition {
        .modifier(active: Arrival(blur: 0, rise: 0, opacity: 0), identity: Arrival(blur: 0, rise: 0, opacity: 1))
    }
}

extension KeyShortcut {
    var parts: [String] {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyLabel)
        return parts
    }

    var spokenDescription: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        words.append(keyLabel)
        return words.joined(separator: " ")
    }
}

extension LocalModel {
    var shortFormat: String {
        if case .nemotronONNX = kind { return "ONNX" }
        return "GGML"
    }

    var abbreviatedPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var displayName: String {
        if case .nemotronONNX = kind { return name }
        guard let preset = ModelPreset.all.first(where: { canReplace($0) }) else { return name }
        return url.lastPathComponent.contains("q5") ? "\(preset.name) Q5" : name
    }
}
