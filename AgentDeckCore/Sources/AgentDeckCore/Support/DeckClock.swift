import Foundation

/// Wall-clock time and sleeping, injected so tests can drive time (`TestClock`).
protocol DeckClock: Sendable {
    func now() -> Date
    /// Sleeps for `duration`. Throws `CancellationError` when the calling task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// The real clock. Sleeps get a small tolerance so the system can coalesce wakeups.
struct SystemClock: DeckClock {
    func now() -> Date { Date() }

    func sleep(for duration: Duration) async throws {
        // 5 % of the interval, at most 1 s: a 16 ms flush gets ~1 ms, a 60 s sweep gets 1 s.
        let tolerance = min(duration / 20, .seconds(1))
        try await Task.sleep(for: duration, tolerance: tolerance)
    }
}

extension Duration {
    /// The duration in seconds as a `Double`.
    var timeInterval: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }

    /// A duration from seconds, clamped at zero.
    static func interval(_ seconds: TimeInterval) -> Duration {
        guard seconds.isFinite, seconds > 0 else { return .zero }
        return .milliseconds(Int64((seconds * 1000).rounded(.up)))
    }
}
