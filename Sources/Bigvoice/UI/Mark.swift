import SwiftUI

enum MarkState: Equatable {
    case idle, dots, listen, wave, caret, check
}

/// One shape, every state. The closed dot is a quiet mouth; it opens into five bars that follow the
/// microphone, folds into travelling dots while the model works, narrows to a caret, then closes to a check.
/// Geometry is the spec's: bar .11 · gap .085 · dot .38, Swell with a 28 ms stagger.
struct VoiceMark: View {
    var size: CGFloat
    var state: MarkState
    var color: Color = Palette.signal
    var envelope: ((TimeInterval) -> Double)?
    var isStatic = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRendering) private var staticRendering

    static let profile: [Double] = [0.42, 0.7, 1, 0.78, 0.5]

    private var still: Bool { isStatic || reduceMotion || staticRendering }
    /// Spec: "Nothing loops in the product unless sound is present." Idle is still; only live states move.
    private var animates: Bool { !still && (state == .listen || state == .wave) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(0..<5, id: \.self) { index in
                    bar(index, t: t)
                }
            }
            .frame(width: size, height: size, alignment: .topLeading)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private struct BarFrame {
        var x: Double, y: Double, w: Double, h: Double, opacity: Double, rotation: Double
    }

    private func frame(_ i: Int) -> BarFrame {
        let s = Double(size), w = 0.11 * s, gap = 0.085 * s
        let x0 = (s - (5 * w + 4 * gap)) / 2
        let xi = x0 + Double(i) * (w + gap)
        switch state {
        case .idle:
            let d = 0.38 * s
            return BarFrame(x: s / 2 - d / 2, y: s / 2 - d / 2, w: d, h: d, opacity: 1, rotation: 0)
        case .listen:
            return BarFrame(x: xi, y: 0.05 * s, w: w, h: 0.9 * s, opacity: 1, rotation: 0)
        case .caret:
            if i == 2 { return BarFrame(x: s / 2 - 0.45 * w, y: 0.1 * s, w: 0.9 * w, h: 0.8 * s, opacity: 1, rotation: 0) }
            return BarFrame(x: s / 2 - w / 2, y: s / 2 - w / 2, w: w, h: w, opacity: 0, rotation: 0)
        case .check:
            let vx = 0.4 * s, vy = 0.76 * s
            if i == 0 { let l = 0.3 * s; return BarFrame(x: vx - w / 2, y: vy - l, w: w, h: l, opacity: 1, rotation: -45) }
            if i == 1 { let l = 0.64 * s; return BarFrame(x: vx - w / 2, y: vy - l, w: w, h: l, opacity: 1, rotation: 40) }
            return BarFrame(x: vx - w / 2, y: vy - w, w: w, h: w, opacity: 0, rotation: 0)
        case .dots, .wave:
            return BarFrame(x: xi, y: s / 2 - w / 2, w: w, h: w, opacity: 1, rotation: 0)
        }
    }

    private func inner(_ i: Int, t: TimeInterval) -> (scale: Double, scaleY: Double, dy: Double) {
        switch state {
        case .listen:
            guard !still, let envelope else { return (1, Self.profile[i], 0) }
            let value = envelope(t) * Self.profile[i] * (0.7 + 0.3 * sin(t * 8.3 + Double(i) * 1.9)) * 1.6 + 0.1
            return (1, max(0.12, min(1, value)), 0)
        case .wave:
            return still ? (1, 1, 0) : (1, 1, sin(t * 7 - Double(i) * 0.8) * Double(size) * 0.14)
        case .idle:
            return (1, 1, 0)
        default:
            return (1, 1, 0)
        }
    }

    private func bar(_ i: Int, t: TimeInterval) -> some View {
        let f = frame(i)
        let motion = inner(i, t: t)
        let capRadius = 0.11 * Double(size) / 2
        return Capsule(style: .continuous)
            .fill(color)
            .scaleEffect(x: motion.scale, y: motion.scale * motion.scaleY, anchor: .center)
            .offset(y: motion.dy)
            .frame(width: max(0.01, f.w), height: max(0.01, f.h))
            .rotationEffect(.degrees(f.rotation), anchor: UnitPoint(x: 0.5, y: 1 - capRadius / max(f.h, 0.01)))
            .opacity(f.opacity)
            .offset(x: f.x, y: f.y)
            .animation(reduceMotion ? Motion.reduced : Motion.swell(stagger: i), value: state)
            .animation(.easeInOut(duration: 0.4), value: color)
    }
}

enum WaveMode: Equatable {
    case idle, listening, working
}

/// Rounded bars that are the microphone, never a screensaver: newest level on the right, scrolling
/// continuously; while the model works, a highlight travels across the frozen recording.
struct BarWaveform: View {
    let meter: LevelMeter
    var count: Int
    var gap: CGFloat
    var mode: WaveMode
    var idleOpacity: Double = 0.35
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: staticRendering || mode == .idle)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let width = max(2, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                let step = count > 1 ? (size.width - width) / CGFloat(count - 1) : 0
                for index in 0..<count {
                    let (height, opacity) = bar(index, t: t)
                    let barHeight = max(width, size.height * CGFloat(height))
                    let rect = CGRect(x: CGFloat(index) * step, y: (size.height - barHeight) / 2, width: width, height: barHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(Palette.signal.opacity(opacity)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bar(_ index: Int, t: TimeInterval) -> (Double, Double) {
        switch mode {
        case .idle:
            return (0.06, idleOpacity)
        case .listening:
            if reduceMotion { return (0.2 + 0.6 * VoiceMark.profile[index % 5], 1) }
            let level = Double(meter.sample(lag: Double(count - 1 - index), at: t))
            return (max(0.06, min(1, level * 1.15)), 1)
        case .working:
            let level = Double(meter.sample(lag: Double(count - 1 - index), at: t))
            let front = (t * 0.8).truncatingRemainder(dividingBy: 1.3) - 0.15
            let d = Double(index) / Double(count) - front
            return (max(0.06, min(1, level * 1.15)), reduceMotion ? 0.6 : 0.22 + 0.78 * exp(-d * d * 50))
        }
    }
}

// MARK: - Icons

enum BrandGlyph {
    case wave, stack, sliders, mic, lock, download, key, check, close, rescan, stop, style
}

/// Icons built from the mark's parts on a 24-unit grid with a 2-unit stroke. Each has one gesture,
/// played when `on` flips (hover, or the item being active).
struct BrandIcon: View {
    let glyph: BrandGlyph
    var on = false
    var size: CGFloat = 18
    var color: Color = Palette.paper
    var background: Color = Palette.char
    var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRendering) private var staticRendering

    private var u: CGFloat { size / 24 }

    var body: some View {
        ZStack(alignment: .topLeading) { parts }
            .frame(width: size, height: size, alignment: .topLeading)
            .accessibilityHidden(true)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * u, y: y * u, width: w * u, height: h * u)
    }

    private func motion(_ delay: Double = 0) -> Animation {
        reduceMotion ? Motion.reduced : Motion.glyph.delay(delay)
    }

    @ViewBuilder private var parts: some View {
        switch glyph {
        case .wave:
            let off: [CGFloat] = [8, 16, 11], lifted: [CGFloat] = [16, 7, 19]
            ForEach(0..<3, id: \.self) { i in
                let height = on ? lifted[i] : off[i]
                Piece(frame: rect([6, 12, 18][i] - 1.25, 12 - height / 2, 2.5, height), radius: 1.25 * u, fill: color)
                    .animation(motion(Double(i) * 0.04), value: on)
            }
        case .stack:
            let tops: [CGFloat] = on ? [2.5, 10.5, 18.5] : [5.5, 10.5, 15.5]
            ForEach(0..<3, id: \.self) { i in
                let wide = i == 1 && on
                Piece(frame: rect(wide ? 2 : 4, tops[i], wide ? 20 : 16, 3), radius: 1.5 * u, fill: color,
                      opacity: i == 1 || !on ? 1 : 0.55)
                    .animation(motion(), value: on)
            }
        case .sliders:
            Piece(frame: rect(3, 7, 18, 2), radius: u, fill: color, opacity: 0.55)
            Piece(frame: rect(3, 15, 18, 2), radius: u, fill: color, opacity: 0.55)
            Piece(frame: rect(on ? 14 : 3, 4.5, 7, 7), radius: 3.5 * u, fill: background, stroke: color, strokeWidth: 2 * u)
                .animation(motion(), value: on)
            Piece(frame: rect(on ? 3 : 14, 12.5, 7, 7), radius: 3.5 * u, fill: background, stroke: color, strokeWidth: 2 * u)
                .animation(motion(0.06), value: on)
        case .mic:
            Piece(frame: rect(8, on ? 1 : 2, 8, 13), radius: 4 * u, fill: on ? color : .clear, stroke: color, strokeWidth: 2 * u)
                .animation(motion(), value: on)
            Piece(frame: rect(11, 17, 2, 4), radius: u, fill: color)
            Piece(frame: rect(7, 20, 10, 2), radius: u, fill: color)
            Piece(frame: rect(on ? 1.5 : 6, 7, 3, 3), radius: 1.5 * u, fill: color, opacity: on ? 1 : 0)
                .animation(motion(), value: on)
            Piece(frame: rect(on ? 19.5 : 15, 7, 3, 3), radius: 1.5 * u, fill: color, opacity: on ? 1 : 0)
                .animation(motion(), value: on)
        case .lock:
            Shackle(inset: u)
                .stroke(color, style: StrokeStyle(lineWidth: 2 * u, lineCap: .butt))
                .frame(width: 9 * u, height: 10 * u)
                .offset(x: 7.5 * u, y: (on ? 4 : 0.5) * u)
                .animation(motion(), value: on)
            Piece(frame: rect(5, 11, 14, 10), radius: 2.5 * u, fill: color)
            Piece(frame: rect(11, 14.5, 2, 3.5), radius: u, fill: background)
        case .download:
            let dy: CGFloat = on ? 4 : 0
            Group {
                Piece(frame: rect(11, 2 + dy, 2, 12), radius: u, fill: color)
                Piece(frame: rect(11, 7 + dy, 2, 7), radius: u, fill: color, rotation: 45, anchor: UnitPoint(x: 0.5, y: 1 - 1.0 / 7))
                Piece(frame: rect(11, 7 + dy, 2, 7), radius: u, fill: color, rotation: -45, anchor: UnitPoint(x: 0.5, y: 1 - 1.0 / 7))
                Piece(frame: rect(on ? 2 : 4, 20, on ? 20 : 16, 2), radius: u, fill: color)
            }
            .animation(motion(), value: on)
        case .key:
            UnevenRoundedRectangle(bottomLeadingRadius: 4 * u, bottomTrailingRadius: 4 * u)
                .fill(color.opacity(0.45))
                .frame(width: 18 * u, height: (on ? 2 : 4) * u)
                .offset(x: 3 * u, y: (on ? 20 : 18) * u)
                .animation(motion(), value: on)
            Piece(frame: rect(3, on ? 4 : 2, 18, 17), radius: 4.5 * u, fill: background, stroke: color, strokeWidth: 2 * u)
                .animation(motion(), value: on)
            Piece(frame: rect(9, on ? 14 : 12, 6, 2), radius: u, fill: color)
                .animation(motion(), value: on)
        case .check:
            let w: CGFloat = 2.2
            Piece(frame: rect(2, 2, 20, 20), radius: 10 * u, stroke: color, strokeWidth: 2 * u,
                  scale: on ? 1 : 0.88, opacity: on ? 1 : 0.45)
                .animation(motion(), value: on)
            Piece(frame: rect(10.5 - w / 2, 11, w, 5), radius: w / 2 * u, fill: color, rotation: -45,
                  anchor: UnitPoint(x: 0.5, y: 1 - (w / 2) / 5), scaleY: on ? 1 : 0.001)
                .animation(motion(), value: on)
            Piece(frame: rect(10.5 - w / 2, 6.5, w, 9.5), radius: w / 2 * u, fill: color, rotation: 42,
                  anchor: UnitPoint(x: 0.5, y: 1 - (w / 2) / 9.5), scaleY: on ? 1 : 0.001)
                .animation(motion(on ? 0.2 : 0), value: on)
        case .close:
            Piece(frame: rect(11, 4, 2, 16), radius: u, fill: color, rotation: on ? 135 : 45)
                .animation(motion(), value: on)
            Piece(frame: rect(11, 4, 2, 16), radius: u, fill: color, rotation: on ? 45 : -45)
                .animation(motion(0.04), value: on)
        case .rescan:
            RescanArc(color: color, unit: u, on: on, spinning: spinning && !reduceMotion && !staticRendering)
        case .stop:
            Piece(frame: rect(6, 6, 12, 12), radius: 3 * u, fill: color)
        case .style:
            // Ragged lines and a stray mark tidy into an even paragraph; the stray lands as its period.
            let widths: [CGFloat] = on ? [18, 18, 11] : [14, 18, 8]
            ForEach(0..<3, id: \.self) { i in
                Piece(frame: rect(3, [5, 11, 17][i], widths[i], 2), radius: u, fill: color)
                    .animation(motion(Double(i) * 0.04), value: on)
            }
            Piece(frame: on ? rect(15.5, 16.75, 2.5, 2.5) : rect(19, 3.5, 3, 3), radius: 1.5 * u, fill: color)
                .animation(motion(0.1), value: on)
        }
    }
}

private struct Piece: View {
    let frame: CGRect
    var radius: CGFloat
    var fill: Color = .clear
    var stroke: Color?
    var strokeWidth: CGFloat = 0
    var rotation: Double = 0
    var anchor: UnitPoint = .center
    var scaleY: CGFloat = 1
    var scale: CGFloat = 1
    var opacity: Double = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(radius, min(frame.width, frame.height) / 2), style: .circular)
        shape.fill(fill)
            .overlay { if let stroke { shape.strokeBorder(stroke, lineWidth: strokeWidth) } }
            .scaleEffect(x: 1, y: scaleY, anchor: anchor)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation), anchor: anchor)
            .opacity(opacity)
            .offset(x: frame.minX, y: frame.minY)
    }
}

private struct Shackle: Shape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = CGRect(x: rect.minX + inset, y: rect.minY + inset, width: rect.width - inset * 2, height: rect.height - inset)
        var path = Path()
        let radius = box.width / 2
        path.move(to: CGPoint(x: box.minX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + radius))
        path.addArc(center: CGPoint(x: box.midX, y: box.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        return path
    }
}

private struct RescanArc: View {
    let color: Color
    let unit: CGFloat
    let on: Bool
    let spinning: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !spinning)) { timeline in
            let spin = spinning ? (timeline.date.timeIntervalSinceReferenceDate * 400).truncatingRemainder(dividingBy: 360) : 0
            ZStack(alignment: .topLeading) {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(color, style: StrokeStyle(lineWidth: 2 * unit, lineCap: .butt))
                    .rotationEffect(.degrees(-45))
                    .frame(width: 14 * unit, height: 14 * unit)
                    .rotationEffect(.degrees((on ? 405 : 45) + spin))
                    .animation(spinning ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.9), value: on)
                    .offset(x: 5 * unit, y: 5 * unit)
                Circle()
                    .fill(color)
                    .frame(width: 4 * unit, height: 4 * unit)
                    .opacity(on || spinning ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: on || spinning)
                    .offset(x: 16.2 * unit, y: 3.2 * unit)
            }
        }
    }
}
