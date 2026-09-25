import Combine
import Foundation

/// Live input levels, read per-frame by canvases so recording never rebuilds the view hierarchy.
/// Only the elapsed-seconds counter is published, and it changes once per second.
@MainActor
final class LevelMeter: ObservableObject {
    static let rate: Double = 30
    static let length = 96

    @Published private(set) var elapsed = 0
    private(set) var history = [Float](repeating: 0, count: LevelMeter.length)
    private(set) var lastPush: TimeInterval = 0

    var latest: Float { history[history.count - 1] }
    var label: String { String(format: "%d:%02d", elapsed / 60, elapsed % 60) }

    func reset() {
        history = Array(repeating: 0, count: Self.length)
        lastPush = Date.timeIntervalSinceReferenceDate
        if elapsed != 0 { elapsed = 0 }
    }

    func push(_ level: Float, duration: TimeInterval) {
        history.removeFirst()
        history.append(level.isFinite ? min(1, max(0, level)) : 0)
        lastPush = Date.timeIntervalSinceReferenceDate
        let seconds = Int(duration)
        if seconds != elapsed { elapsed = seconds }
    }

    /// Level `lag` samples in the past, interpolated between pushes so motion stays fluid at display rate.
    func sample(lag: Double, at now: TimeInterval) -> Float {
        let progress = min(1, max(0, (now - lastPush) * Self.rate))
        let position = Double(history.count - 1) - max(0, lag) - 1 + progress
        let clamped = min(Double(history.count - 1), max(0, position))
        let lower = Int(clamped.rounded(.down))
        let upper = min(history.count - 1, lower + 1)
        let fraction = Float(clamped - Double(lower))
        return history[lower] + (history[upper] - history[lower]) * fraction
    }

    /// Smoothed live envelope for the mark's bars (the spec's 0.25-per-frame follower).
    func envelope(at now: TimeInterval) -> Double {
        Double(sample(lag: 0, at: now) + sample(lag: 1, at: now) + sample(lag: 2, at: now)) / 3
    }

    #if DEBUG
    func loadPreview(_ levels: [Float], seconds: Int) {
        var padded = Array(repeating: Float(0), count: max(0, Self.length - levels.count)) + levels.suffix(Self.length)
        if padded.count > Self.length { padded = Array(padded.suffix(Self.length)) }
        history = padded
        lastPush = Date.timeIntervalSinceReferenceDate
        elapsed = seconds
    }
    #endif
}
