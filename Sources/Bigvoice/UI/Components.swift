import AppKit
import BigvoiceCore
import SwiftUI

// MARK: - Buttons

/// The spec's three button voices: the one Signal action, outline pills, and Signal text links.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case signal, outline, filledSignal, quiet, text }
    var kind: Kind = .outline
    var height: CGFloat = 36
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, height: height, width: width)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    let height: CGFloat
    let width: CGFloat?
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .padding(.leading, width == nil ? leading : 0)
            .padding(.trailing, width == nil ? trailing : 0)
            .frame(width: width, height: kind == .text ? nil : height)
            .background { if kind != .text { Capsule().fill(background) } }
            .overlay { if kind != .text && kind != .quiet { Capsule().strokeBorder(border, lineWidth: 1) } }
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.2), value: pressed)
            .animation(.easeInOut(duration: 0.3), value: hovering)
    }

    private var font: Font {
        switch kind {
        case .signal: return BrandFont.ui(14, weight: 600)
        case .filledSignal: return BrandFont.ui(12.5, weight: 600)
        case .text: return BrandFont.ui(12.5, weight: 500)
        default: return BrandFont.ui(height >= 44 ? 14 : 13, weight: 500)
        }
    }

    private var leading: CGFloat {
        switch kind {
        case .signal: return 16
        case .text: return 0
        case .quiet: return 10
        default: return height >= 44 ? 14 : 14
        }
    }

    private var trailing: CGFloat {
        switch kind {
        case .signal: return 20
        case .text: return 0
        default: return height >= 44 ? 18 : 14
        }
    }

    private var foreground: Color {
        switch kind {
        case .signal, .filledSignal: return Palette.ink
        case .outline: return Palette.paper
        case .quiet: return hovering ? Palette.paper : Palette.stone
        case .text: return hovering ? Palette.paper : Palette.signal
        }
    }

    private var background: Color {
        switch kind {
        case .signal, .filledSignal: return Palette.signal
        case .outline, .quiet: return hovering ? Palette.line(0.06) : Color.clear
        case .text: return .clear
        }
    }

    private var border: Color {
        switch kind {
        case .signal, .filledSignal: return Palette.signal
        default: return hovering ? Palette.line(0.3) : Palette.line(0.16)
        }
    }
}

/// Tracks hover for icon gestures inside button labels.
struct HoverReader<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false
    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

// MARK: - Keycaps

struct Keycap: View {
    enum Size { case regular, small }
    let label: String
    var size: Size = .regular
    var pressed = false

    var body: some View {
        let small = size == .small
        let shape = RoundedRectangle(cornerRadius: small ? 8 : 9, style: .continuous)
        // Geist Mono draws ⌃ ⌥ ⇧ ⌘ undersized; the system face keeps modifiers optically equal to letters.
        let isModifier = label.count == 1 && "⌃⌥⇧⌘".contains(label)
        Text(label)
            .font(isModifier ? .system(size: small ? 12.5 : 13.5, weight: .medium) : BrandFont.mono(small ? 12 : 13, weight: 500))
            .foregroundStyle(pressed ? Palette.signal : Palette.paper)
            .fixedSize()
            .padding(.horizontal, small ? 9 : 11)
            .frame(minWidth: small ? 30 : 36, minHeight: small ? 28 : 34)
            .background(shape.fill(pressed ? Palette.signal(0.16) : Palette.surface))
            .overlay(shape.strokeBorder(Palette.line(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: pressed ? 1 : (small ? 2 : 3))
            .offset(y: pressed ? 2 : 0)
            .animation(.easeInOut(duration: 0.16), value: pressed)
    }
}

struct Keycaps: View {
    let parts: [String]
    var size: Keycap.Size = .regular
    var pressed = false

    var body: some View {
        HStack(spacing: size == .small ? 5 : 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Keycap(label: part, size: size, pressed: pressed)
            }
        }
        .padding(.bottom, size == .small ? 2 : 3)
        .accessibilityElement(children: .ignore)
    }
}

// MARK: - Surfaces

struct Panel<Content: View>: View {
    var radius: CGFloat = 20
    var border: Color = Palette.line(0.08)
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.char))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(BrandFont.ui(13.5, weight: 500)).foregroundStyle(Palette.paper)
                if let detail {
                    Text(detail).font(BrandFont.ui(12.5)).foregroundStyle(Palette.stone)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

struct RowDivider: View {
    var inset: CGFloat = 18
    var body: some View {
        Palette.line(0.07).frame(height: 1).padding(.horizontal, inset)
    }
}

struct SectionHeading<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(BrandFont.ui(17, weight: 600)).tracking(-0.17).foregroundStyle(Palette.paper)
                if let detail {
                    Text(detail).font(BrandFont.ui(12.5)).foregroundStyle(Palette.stone)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension SectionHeading where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(BrandFont.display(40, weight: 620, width: 90))
                .tracking(-1.4)
                .foregroundStyle(Palette.paper)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(BrandFont.ui(15)).foregroundStyle(Palette.stone)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct MonoLabel: View {
    let text: String
    var size: CGFloat = 11.5
    var color: Color = Palette.stone

    var body: some View {
        Text(text)
            .font(BrandFont.mono(size, weight: 500))
            .tracking(size * 0.05)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct StatusPill: View {
    let label: String
    let lit: Bool
    let glowing: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(lit ? Palette.signal : Palette.stone)
                .frame(width: 7, height: 7)
                .background {
                    Circle().fill(Palette.signal(0.25))
                        .frame(width: 15, height: 15)
                        .scaleEffect(glowing ? 1 : 0.4)
                        .opacity(glowing ? 1 : 0)
                }
                .animation(.easeInOut(duration: 0.4), value: glowing)
                .animation(.easeInOut(duration: 0.3), value: lit)
            Text(label)
                .font(BrandFont.ui(12, weight: 500))
                .foregroundStyle(Palette.stone)
                .contentTransition(.opacity)
                .animation(Motion.fade, value: label)
        }
        .padding(.vertical, 7)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .background(Capsule().fill(Palette.line(0.05)))
        .overlay(Capsule().strokeBorder(Palette.line(0.08)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Controls

/// 40 × 24 track, 18 pt knob. Signal when on; paper knob on a quiet track when off. Settle curve.
struct BrandToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: .leading) {
                Capsule().fill(configuration.isOn ? Palette.signal : Palette.line(0.14))
                    .frame(width: 40, height: 24)
                Circle().fill(configuration.isOn ? Palette.ink : Palette.paper)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, x: 0, y: 1)
                    .offset(x: configuration.isOn ? 19 : 3)
            }
            .animation(Motion.settle, value: configuration.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

struct BrandSelect<Value: Hashable>: View {
    struct Option { let label: String; let value: Value; var enabled = true }
    let options: [Option]
    @Binding var selection: Value
    var width: CGFloat
    var accessibilityLabel: String

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.label) { selection = option.value }.disabled(!option.enabled)
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.label ?? "Choose")
                    .font(BrandFont.ui(13))
                    .foregroundStyle(Palette.paper)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.stone)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line(0.1)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Disk size to scale (width) with install progress (Signal fill).
struct SizeBar: View {
    let scale: Double
    let fill: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Palette.line(0.05))
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line(0.14))
                GeometryReader { proxy in
                    Capsule().fill(Palette.signal)
                        .frame(width: proxy.size.width * CGFloat(min(1, max(0, fill))))
                        .animation(.linear(duration: 0.2), value: fill)
                }
            }
            .frame(width: 180 * CGFloat(scale))
            .clipShape(Capsule())
        }
        .frame(width: 180, height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Transcript

/// Wraps words like text; used so each word can land individually.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5.7
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct TranscriptWords: View {
    let text: String
    var emphasizeNewest: Bool
    var tone: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        let words = words
        FlowLayout(spacing: 5.7, lineSpacing: 2) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(BrandFont.ui(19))
                    .tracking(-0.1)
                    .foregroundStyle(emphasizeNewest && index == words.count - 1 ? Palette.signal : tone)
                    .transition(reduceMotion ? .opacity : .wordArrival)
            }
        }
        .animation(reduceMotion ? Motion.reduced : Motion.swell, value: words.count)
        .animation(.easeInOut(duration: 0.6), value: tone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - Toasts

struct ToastHost: View {
    @ObservedObject var controller: AppController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let notice = controller.notice {
                ToastView(notice: notice) { controller.dismissNotice(notice.id) }
                    .id(notice.id)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .pageSwap, removal: .crossfade))
            }
        }
        .padding(.bottom, 22)
        .padding(.horizontal, 28)
        .animation(reduceMotion ? Motion.reduced : Motion.settle, value: controller.notice?.id)
    }
}

struct ToastView: View {
    let notice: AppNotice
    let dismiss: () -> Void
    @State private var hoveringClose = false
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if notice.kind == .info {
                    VoiceMark(size: 18, state: .check, color: Palette.signal, isStatic: true)
                } else {
                    Image(systemName: notice.kind == .warning ? "exclamationmark.triangle.fill" : "exclamationmark.octagon.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.caution)
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(BrandFont.ui(13.5, weight: 600)).foregroundStyle(Palette.paper)
                Text(notice.detail).font(BrandFont.ui(12.5)).foregroundStyle(Palette.stone)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(action: dismiss) {
                BrandIcon(glyph: .close, on: hoveringClose, size: 14, color: Palette.stone)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.char))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line(0.12)))
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 14)
        .task(id: notice.id) {
            guard notice.kind == .info, !staticRendering else { return }
            try? await Task.sleep(for: .seconds(4.5))
            if !Task.isCancelled { withAnimation(Motion.hush) { dismiss() } }
        }
    }
}
