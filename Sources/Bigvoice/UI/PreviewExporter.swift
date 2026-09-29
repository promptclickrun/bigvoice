#if DEBUG
import AppKit
import BigvoiceCore
import BigvoiceRuntime
import Foundation
import SwiftUI

/// Renders every screen and state for design review, using real discovery results from this Mac
/// and clearly synthetic voice levels and transcripts.
@MainActor
enum PreviewExporter {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let domain = "com.bigvoice.preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw PreviewError(message: "Couldn't create isolated preview preferences.")
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        let controller = AppController(preferences: PreferencesStore(defaults: defaults))
        await controller.loadPreviewModels()
        let window = NSSize(width: 1116, height: 800)
        let phrase = "Move the design review to Thursday, and loop in the platform team before we lock the agenda."
        let heard = "um so move the design review to uh thursday and loop in the the platform team before we lock the agenda"
        let polished = PolishOutcome(text: phrase, heard: heard, requested: .polished, applied: .polished, tone: .natural,
                                     context: .documents, engine: .appleIntelligence, milliseconds: 420)
        let ready = (microphone: true, accessibility: true)
        await controller.loadPreviewStyle()

        for page in AppPage.allCases {
            controller.page = page
            controller.applyPreview(phase: .idle, mode: nil, permissions: ready)
            try render(PreviewRoot(controller: controller), size: window, to: directory.appendingPathComponent("\(page.rawValue.lowercased()).png"))
            try renderFull(page: page, controller: controller, to: directory.appendingPathComponent("\(page.rawValue.lowercased())-full.png"))
        }

        controller.page = .dictation
        let states: [(String, DictationPhase, DictationMode?, String, String?, Delivery?, Bool)] = [
            ("dictation-listening", .recording(.pushToTalk), .pushToTalk, "Move the design review to Thursday, and loop in", nil, nil, false),
            ("dictation-transcribing", .transcribing, .practice, phrase, nil, nil, false),
            ("dictation-polishing", .transcribing, .practice, "So move the design review to thursday and loop in the platform team before we lock the agenda",
             nil, nil, true),
            ("dictation-done", .idle, nil, "", phrase,
             Delivery(title: "Inserted into Notes", detail: "Polished · Natural", instruction: "Inserted · you decide when to send"), false)
        ]
        for (name, phase, mode, live, transcript, delivered, polishing) in states {
            controller.applyPreview(phase: phase, mode: mode, levels: speech(), seconds: 4, transcript: transcript,
                                    live: live, delivered: delivered, permissions: ready,
                                    heard: transcript == nil ? nil : heard, outcome: transcript == nil ? nil : polished,
                                    polishing: polishing)
            try render(PreviewRoot(controller: controller), size: window, to: directory.appendingPathComponent("\(name).png"))
        }
        var fallback = polished
        fallback.applied = .clean
        fallback.text = "So move the design review to thursday and loop in the platform team before we lock the agenda."
        fallback.note = "Apple Intelligence added a number you didn't say"
        controller.applyPreview(phase: .idle, mode: nil, transcript: fallback.text, permissions: ready, heard: heard, outcome: fallback)
        try render(PreviewRoot(controller: controller), size: window, to: directory.appendingPathComponent("dictation-fallback.png"))
        controller.applyPreview(phase: .idle, mode: nil, permissions: (false, false))
        try render(PreviewRoot(controller: controller), size: window, to: directory.appendingPathComponent("dictation-setup.png"))
        controller.applyPreview(phase: .idle, mode: nil, permissions: ready)
        try render(PreviewRoot(controller: controller, height: 660), size: NSSize(width: 900, height: 660), to: directory.appendingPathComponent("dictation-compact.png"))

        controller.meter.loadPreview(speech(), seconds: 4)
        let capsules: [(String, CapsuleContent, String?)] = [
            ("capsule-arming", .arming, "Opening your microphone · Esc to cancel"),
            ("capsule-listening", .listening, "Release ⌃ ⌥ Space to finish"),
            ("capsule-transcribing", .transcribing, "Transcribing offline · Esc to cancel"),
            ("capsule-polishing", .polishing("Professional · on your Mac"), "Polishing on this Mac · Esc to cancel"),
            ("capsule-inserting", .inserting, "Inserting into your original app"),
            ("capsule-done", .delivered(Delivery(title: "Inserted into Mail", detail: "Polished · Professional",
                                                 instruction: "Inserted · you decide when to send")), "Inserted · you decide when to send"),
            ("capsule-attention", .attention(kind: .warning, title: "Your words are ready", id: UUID()), nil)
        ]
        for (name, content, instruction) in capsules {
            try render(OverlayPreview(content: content, instruction: instruction, meter: controller.meter),
                       size: OverlayMetrics.size, to: directory.appendingPathComponent("\(name).png"))
        }
        let marks: [MarkState] = [.idle, .dots, .listen, .wave, .caret, .check]
        try render(HStack(spacing: 28) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, state in
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Palette.ink).frame(width: 64, height: 64)
                    VoiceMark(size: 36, state: state, color: state == .idle ? Palette.paper : Palette.signal, isStatic: true)
                }
            }
        }.padding(28).background(Palette.char), size: NSSize(width: 580, height: 120), to: directory.appendingPathComponent("marks.png"))
        let glyphs: [BrandGlyph] = [.wave, .style, .stack, .sliders, .mic, .lock, .download, .key, .check, .close, .rescan]
        try render(VStack(spacing: 18) {
            ForEach([false, true], id: \.self) { on in
                HStack(spacing: 22) {
                    ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                        BrandIcon(glyph: glyph, on: on, size: 36, color: on ? Palette.signal : Palette.paper, background: Palette.surface)
                            .frame(width: 60, height: 60)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
                    }
                }
            }
        }.padding(24).background(Palette.char), size: NSSize(width: 928, height: 200), to: directory.appendingPathComponent("icons.png"))
        for (name, state, busy) in [("status-idle", MarkState.idle, false), ("status-listening", .listen, true), ("status-done", .check, true)] {
            try write(StatusGlyph.image(state: state, busy: busy, ready: true, levels: nil, time: 0), scale: 8,
                      to: directory.appendingPathComponent("\(name).png"))
        }
        await controller.shutdown()
        print("Rendered previews to \(directory.path)")
    }

    /// A synthetic speech-like envelope: syllable bursts under a slower phrase contour.
    private static func speech() -> [Float] {
        (0..<LevelMeter.length).map { index in
            let t = Double(LevelMeter.length - 1 - index) / LevelMeter.rate + 0.4
            let gate = max(0, min(1, (sin(t * 0.63 * 3) + 0.45) * 2.2))
            let syllable = pow(abs(sin(t * 4.1 * 1.6 + sin(t * 1.3) * 2)), 1.4)
            return Float(min(1, max(0.04, gate * (0.16 + 0.84 * syllable) * (0.82 + 0.18 * sin(t * 17)))))
        }
    }

    private static func renderFull(page: AppPage, controller: AppController, to url: URL) throws {
        let width: CGFloat = 880
        let content: AnyView
        switch page {
        case .dictation: content = AnyView(DictationView(controller: controller, meter: controller.meter))
        case .style: content = AnyView(StyleView(controller: controller, preview: controller.stylePreview))
        case .models: content = AnyView(ModelsView(controller: controller))
        case .settings: content = AnyView(SettingsView(controller: controller))
        }
        let padded = content.padding(.horizontal, 48).padding(.vertical, 44).frame(width: width).background(Palette.ink)
        let probe = NSHostingView(rootView: padded.environment(\.staticRendering, true).environment(\.colorScheme, .dark))
        probe.appearance = NSAppearance(named: .darkAqua)
        try render(padded, size: NSSize(width: width, height: max(400, ceil(probe.fittingSize.height))), to: url)
    }

    private static func render<Content: View>(_ content: Content, size: NSSize, to url: URL) throws {
        let renderer = ImageRenderer(content: content
            .environment(\.staticRendering, true)
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped())
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PreviewError(message: "Couldn't render \(url.lastPathComponent).")
        }
        try data.write(to: url)
    }

    private static func write(_ image: NSImage, scale: CGFloat, to url: URL) throws {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PreviewError(message: "Couldn't allocate \(url.lastPathComponent).")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(hex: 0x070504).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError(message: "Couldn't encode \(url.lastPathComponent).")
        }
        try data.write(to: url)
    }

    /// RootView without the ScrollView (which snapshot renderers can't draw), same geometry.
    private struct PreviewRoot: View {
        @ObservedObject var controller: AppController
        var height: CGFloat = 800
        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                Sidebar(controller: controller).frame(width: 236, height: height)
                ZStack(alignment: .bottom) {
                    Palette.ink
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            switch controller.page {
                            case .dictation: DictationView(controller: controller, meter: controller.meter)
                            case .style: StyleView(controller: controller, preview: controller.stylePreview)
                            case .models: ModelsView(controller: controller)
                            case .settings: SettingsView(controller: controller)
                            }
                        }
                        .padding(.horizontal, 48)
                        .padding(.top, 44)
                        .frame(maxWidth: 880, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    ToastHost(controller: controller)
                }
                .frame(height: height, alignment: .top)
                .clipped()
            }
            .frame(height: height, alignment: .top)
            .background(Palette.ink)
        }
    }

    private struct PreviewError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
#endif
