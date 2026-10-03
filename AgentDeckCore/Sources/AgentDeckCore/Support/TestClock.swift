import Foundation
import Synchronization

/// A manually driven clock for tests. Time only moves on `advance(by:)` / `advance(to:)`, which resume
/// every sleeper whose deadline has passed, earliest first. Sleepers honour task cancellation.
final class TestClock: DeckClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        /// Ids cancelled before their continuation was registered.
        var cancelled: Set<UInt64> = []
    }

    private let state: Mutex<State>

    /// Starts at `now` (default: 2026-10-03T00:00:00Z, just after the fixture sessions).
    init(now: Date = Date(timeIntervalSince1970: 1_790_985_600)) {
        state = Mutex(State(now: now))
    }

    func now() -> Date { state.withLock { $0.now } }

    /// Number of tasks currently sleeping on this clock.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// The earliest pending sleeper deadline.
    var nextDeadline: Date? { state.withLock { $0.sleepers.map(\.deadline).min() } }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { s -> UInt64 in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case wait, resume, cancel }
                let action = state.withLock { s -> Action in
                    if s.cancelled.remove(id) != nil { return .cancel }
                    let deadline = s.now.addingTimeInterval(duration.timeInterval)
                    if deadline <= s.now { return .resume }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch action {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                if let index = s.sleepers.firstIndex(where: { $0.id == id }) {
                    return s.sleepers.remove(at: index).continuation
                }
                s.cancelled.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and resumes due sleepers.
    func advance(by duration: Duration) {
        let target = state.withLock { $0.now.addingTimeInterval(duration.timeInterval) }
        advance(to: target)
    }

    /// Moves time to `date` (never backwards) and resumes due sleepers.
    func advance(to date: Date) {
        let due = state.withLock { s -> [Sleeper] in
            if date > s.now { s.now = date }
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
