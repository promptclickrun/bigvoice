import AppKit
import BigvoiceCore
import SwiftUI

struct ModelsView: View {
    @ObservedObject var controller: AppController
    @State private var pendingRemoval: LocalModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            PageTitle(title: "A little room for your voice.",
                      subtitle: "Use what you have before downloading more. Existing models stay in their original folders.")
            actions
            local
            catalog
            if !controller.incompatibleModels.isEmpty || !controller.scanWarnings.isEmpty { findings }
        }
        .confirmationDialog("Remove this downloaded model?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            if let model = pendingRemoval {
                Button("Delete \(model.displayName) (\(model.sizeLabel))", role: .destructive) {
                    controller.removeManagedModel(model)
                    pendingRemoval = nil
                }
            }
            Button("Keep model", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Only the file bigvoice downloaded is deleted. Models that belong to other apps are never touched.")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Add model file…", action: controller.addModelFile)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 36))
            Button("Search a folder…", action: controller.addSearchFolder)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 36))
            Spacer()
            HoverReader { hovering in
                Button { Task { await controller.rescan() } } label: {
                    HStack(spacing: 8) {
                        BrandIcon(glyph: .rescan, on: hovering, size: 16,
                                  color: hovering ? Palette.paper : Palette.stone, spinning: controller.isScanning)
                        Text(controller.isScanning ? "Searching" : "Rescan")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .quiet, height: 36))
                .disabled(controller.isScanning)
            }
        }
        .disabled(!controller.canChangeModel)
    }

    private var local: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "On this Mac", detail: nil) {
                Text("\(controller.models.count) available")
                    .font(BrandFont.mono(12, weight: 400)).foregroundStyle(Palette.stone)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: controller.models.count)
            }
            if controller.models.isEmpty {
                Panel {
                    HStack(spacing: 16) {
                        tile(state: .idle, color: Palette.stone, isStatic: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(controller.isScanning ? "Listening for models on this Mac…" : "No compatible models yet")
                                .font(BrandFont.ui(14.5, weight: 600)).foregroundStyle(Palette.paper)
                            Text("Install a small one below, or add a model you already have. Nothing downloads on its own.")
                                .font(BrandFont.ui(12.5)).foregroundStyle(Palette.stone)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                }
            } else {
                ForEach(controller.models, id: \.id) { model in
                    LocalModelCard(controller: controller, model: model) { pendingRemoval = model }
                }
            }
        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Find your fit", detail: "Open-weight Whisper models · MIT licensed · Runs offline after installation")
            Panel {
                ForEach(Array(ModelPreset.all.enumerated()), id: \.element.id) { index, preset in
                    if index > 0 { Palette.line(0.07).frame(height: 1) }
                    CatalogRow(controller: controller, preset: preset)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("Bars show disk size to scale. Sizes are downloads, not working memory. English models use 5-bit quantization.")
                .font(BrandFont.ui(12)).foregroundStyle(Palette.stone).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Also found", detail: "Shown so nothing is downloaded twice. bigvoice never copies or changes these.")
            Panel {
                ForEach(Array(controller.incompatibleModels.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { RowDivider() }
                    SettingRow(title: model.name, detail: [model.format + " · " + model.source, model.reason].compactMap { $0 }.joined(separator: "\n")) {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
                            .buttonStyle(PillButtonStyle(kind: .quiet, height: 32))
                    }
                }
                if !controller.scanWarnings.isEmpty {
                    if !controller.incompatibleModels.isEmpty { RowDivider() }
                    VStack(alignment: .leading, spacing: 6) {
                        MonoLabel(text: "SEARCH NOTES")
                        ForEach(controller.scanWarnings, id: \.self) { warning in
                            Text(warning).font(BrandFont.ui(12)).foregroundStyle(Palette.stone)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                }
            }
        }
    }

    private func tile(state: MarkState, color: Color, isStatic: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.ink)
            VoiceMark(size: 22, state: state, color: color, isStatic: isStatic)
        }
        .frame(width: 44, height: 44)
    }
}

private struct LocalModelCard: View {
    @ObservedObject var controller: AppController
    let model: LocalModel
    let requestRemoval: () -> Void

    private var active: Bool { controller.preferences.value.selectedModelPath == model.url.path }
    private var preparing: Bool { controller.preparingModelID == model.id }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.ink)
                VoiceMark(size: 22, state: active ? .listen : .idle, color: active ? Palette.signal : Palette.stone, isStatic: true)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.displayName).font(BrandFont.ui(14.5, weight: 600)).foregroundStyle(Palette.paper)
                    if active {
                        Text("ACTIVE")
                            .font(BrandFont.mono(10, weight: 600)).tracking(0.8)
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Palette.signal))
                            .transition(.crossfade)
                    }
                }
                Text("\(model.languageLabel) · \(model.sizeLabel) · \(model.formatLabel) · \(model.isManaged ? "bigvoice download" : "reused from \(model.source)")")
                    .font(BrandFont.ui(12.5)).foregroundStyle(Palette.stone)
                    .lineLimit(1)
                Text(model.abbreviatedPath)
                    .font(BrandFont.mono(11, weight: 400)).foregroundStyle(Palette.stone)
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.url.path)
            }
            Spacer(minLength: 12)
            ZStack(alignment: .trailing) {
                if preparing {
                    HStack(spacing: 8) {
                        VoiceMark(size: 18, state: .wave, color: Palette.signal)
                        Text("Loading").font(BrandFont.mono(11.5, weight: 500)).foregroundStyle(Palette.stone)
                    }
                    .transition(.crossfade)
                } else if !active {
                    Button("Use") { controller.choose(model) }
                        .buttonStyle(PillButtonStyle(kind: .filledSignal, height: 34, width: 96))
                        .disabled(!controller.canChangeModel)
                        .transition(.crossfade)
                }
            }
            .animation(Motion.swell, value: preparing)
            Menu {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.url.path, forType: .string)
                }
                if model.isManaged {
                    Divider()
                    Button("Remove Download…", role: .destructive, action: requestRemoval).disabled(!controller.canChangeModel)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.stone)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More options for \(model.displayName)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.char))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(active ? Palette.signal(0.35) : Palette.line(0.08), lineWidth: 1))
        .animation(.easeInOut(duration: 0.4), value: active)
    }
}

private struct CatalogRow: View {
    @ObservedObject var controller: AppController
    let preset: ModelPreset

    private static let largest = Double(ModelPreset.all.map(\.bytes).max() ?? 1)
    private var existing: LocalModel? { controller.models.first { $0.canReplace(preset) } }
    private var progress: InstallationProgress? {
        guard let progress = controller.installation, progress.presetID == preset.id else { return nil }
        return progress
    }
    private var inUse: Bool { existing.map { $0.url.path == controller.preferences.value.selectedModelPath } ?? false }

    private var stageText: String? {
        guard let progress else { return nil }
        switch progress.stage {
        case "Downloading": return "Downloading from the pinned Hugging Face revision"
        case "Verifying SHA-256": return "Verifying byte count and SHA-256"
        case "Preparing for dictation": return "Installed atomically · loading for dictation"
        default: return "Checking for a copy you already have…"
        }
    }

    private var sizeText: String {
        if inUse { return "In use · no extra space" }
        if existing != nil { return "On this Mac · no extra space" }
        if let progress, progress.stage == "Downloading" {
            let total = Double(preset.bytes) / 1_000_000
            return String(format: "%.1f of %.1f MB", total * progress.fraction, total)
        }
        return preset.sizeLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(preset.displayName).font(BrandFont.ui(14.5, weight: 600)).foregroundStyle(Palette.paper)
                        if preset.id == "base-en" {
                            Text("RECOMMENDED").font(BrandFont.mono(10, weight: 600)).tracking(0.8).foregroundStyle(Palette.signal)
                        }
                    }
                    Text(preset.multilingual ? "Multilingual · Auto-detect language" : "English · Compact Q5")
                        .font(BrandFont.ui(12.5)).foregroundStyle(Palette.stone)
                }
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    SizeBar(scale: Double(preset.bytes) / Self.largest,
                            fill: existing != nil ? 1 : (progress?.stage == "Downloading" ? progress?.fraction ?? 0 : (progress != nil && progress?.stage != "Checking this Mac first" ? 1 : 0)))
                    Text(sizeText)
                        .font(BrandFont.mono(11.5, weight: 400))
                        .foregroundStyle(inUse || progress != nil ? Palette.signal : Palette.stone)
                        .contentTransition(.numericText())
                }
                .frame(width: 180, alignment: .leading)
                actionButton
            }
            if let stageText {
                Text(stageText)
                    .font(BrandFont.mono(11.5, weight: 400))
                    .foregroundStyle(Palette.stone)
                    .transition(.opacity.combined(with: .offset(y: -4)))
                    .id(stageText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .animation(Motion.swell, value: stageText)
    }

    @ViewBuilder private var actionButton: some View {
        Group {
            if progress != nil {
                Button("Cancel", action: controller.cancelInstallation)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 34, width: 96))
            } else if inUse {
                Text("In use")
                    .font(BrandFont.ui(12.5, weight: 600)).foregroundStyle(Palette.stone)
                    .frame(width: 96, height: 34)
                    .overlay(Capsule().strokeBorder(Palette.line(0.08)))
            } else if existing != nil {
                Button("Use") { controller.install(preset) }
                    .buttonStyle(PillButtonStyle(kind: .filledSignal, height: 34, width: 96))
                    .disabled(!controller.canChangeModel || controller.isScanning)
            } else {
                Button("Install") { controller.install(preset) }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 34, width: 96))
                    .disabled(!controller.canChangeModel || controller.isScanning)
            }
        }
        .frame(width: 96)
        .animation(.easeInOut(duration: 0.3), value: progress != nil)
        .animation(.easeInOut(duration: 0.3), value: inUse)
    }
}

extension ModelPreset {
    var displayName: String { multilingual ? name : "\(name) Q5" }
}
