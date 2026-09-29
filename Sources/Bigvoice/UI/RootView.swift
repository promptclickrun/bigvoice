import BigvoiceCore
import SwiftUI

struct RootView: View {
    @ObservedObject var controller: AppController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(controller: controller)
                .frame(width: 236)
            ZStack(alignment: .bottom) {
                Palette.ink
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        page
                            .id(controller.page)
                            .transition(reduceMotion ? .opacity : .pageSwap)
                    }
                    .padding(.horizontal, 48)
                    .padding(.top, 44)
                    .padding(.bottom, 48)
                    .frame(maxWidth: 880, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                ToastHost(controller: controller)
            }
        }
        .background(Palette.ink)
        .frame(minWidth: 900, minHeight: 660)
        .environment(\.colorScheme, .dark)
        .tint(Palette.signal)
        .animation(reduceMotion ? Motion.reduced : Motion.settle, value: controller.page)
        .onReceive(permissionTimer) { _ in controller.refreshPermissions() }
    }

    @ViewBuilder private var page: some View {
        switch controller.page {
        case .dictation: DictationView(controller: controller, meter: controller.meter)
        case .style: StyleView(controller: controller, preview: controller.stylePreview)
        case .models: ModelsView(controller: controller)
        case .settings: SettingsView(controller: controller)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var controller: AppController
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let items: [(AppPage, BrandGlyph)] = [(.dictation, .wave), (.style, .style), (.models, .stack), (.settings, .sliders)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VoiceMark(size: 26, state: controller.markState, color: Palette.signal,
                          envelope: { controller.meter.envelope(at: $0) })
                Text("bigvoice")
                    .font(BrandFont.display(23, weight: 700, width: 88))
                    .tracking(-0.8)
                    .foregroundStyle(Palette.paper)
            }
            .padding(.top, 64)
            .padding(.horizontal, 8)
            .padding(.bottom, 30)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("bigvoice")

            VStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    NavItem(page: item.0, glyph: item.1, active: controller.page == item.0, namespace: selection,
                            shortcut: KeyEquivalent(Character("\(index + 1)"))) {
                        controller.page = item.0
                    }
                }
            }
            .animation(reduceMotion ? Motion.reduced : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45), value: controller.page)

            Spacer(minLength: 20)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.char)
        .overlay(alignment: .trailing) { Palette.line(0.07).frame(width: 1) }
    }

    private var footer: some View {
        let model = controller.selectedModel
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(model == nil ? Palette.stone : Palette.signal).frame(width: 6, height: 6)
                    Text(model?.displayName ?? "No model yet")
                        .font(BrandFont.ui(12.5, weight: 600))
                        .foregroundStyle(Palette.paper)
                        .lineLimit(1)
                }
                Text(model.map { "\($0.languageLabel) · \($0.sizeLabel)" } ?? "Choose one in Models")
                    .font(BrandFont.mono(11.5, weight: 400))
                    .foregroundStyle(Palette.stone)
            }
            Palette.line(0.08).frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                BrandIcon(glyph: .lock, on: true, size: 14, color: Palette.stone, background: Palette.ink)
                    .padding(.top, 1)
                Text("On your Mac.\nOff the cloud.")
                    .font(BrandFont.ui(12))
                    .foregroundStyle(Palette.stone)
                    .lineSpacing(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.ink))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line(0.07)))
        .accessibilityElement(children: .combine)
    }
}

private struct NavItem: View {
    let page: AppPage
    let glyph: BrandGlyph
    let active: Bool
    let namespace: Namespace.ID
    let shortcut: KeyEquivalent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                BrandIcon(glyph: glyph, on: active || hovering, size: 18,
                          color: active ? Palette.paper : Palette.stone, background: Palette.char)
                Text(page.rawValue)
                    .font(BrandFont.ui(13.5, weight: active ? 600 : 450))
                Spacer(minLength: 0)
                Circle().fill(Palette.signal).frame(width: 5, height: 5).opacity(active ? 1 : 0)
            }
            .foregroundStyle(active ? Palette.paper : Palette.stone)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.line(0.07))
                        .matchedGeometryEffect(id: "highlight", in: namespace)
                }
            }
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.3), value: active)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
