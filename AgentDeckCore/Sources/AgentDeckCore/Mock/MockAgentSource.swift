import Foundation

/// Simulated Claude Code tasks and subagents, for demos, screenshots and UI profiling.
///
/// `.demo` runs a handful of realistic sessions with compressed durations (a task takes
/// 1–4 minutes). `.stress` keeps 20 active tasks with about 15 agents each.
public final class MockAgentSource: AgentSource {
    public enum Scenario: Sendable { case demo, stress }

    public let scenario: Scenario
    private let simulator: MockSimulator

    /// A fresh, randomly seeded simulation running in real time.
    public convenience init(scenario: Scenario) {
        self.init(scenario: scenario, seed: UInt64.random(in: .min ... .max))
    }

    /// - Parameters:
    ///   - seed: Same seed, same simulation.
    ///   - speed: Simulated seconds per real second (1 = real time). Snapshot dates use simulated time.
    ///   - startDate: Simulated time when `updates()` is first called; defaults to the real time then.
    public init(scenario: Scenario, seed: UInt64, speed: Double = 1, startDate: Date? = nil) {
        precondition(speed > 0, "speed must be positive")
        self.scenario = scenario
        simulator = MockSimulator(scenario: scenario, seed: seed, speed: speed, startDate: startDate)
    }

    public func updates() async -> AsyncStream<DeckUpdate> { await simulator.updates() }

    public func stop() async { await simulator.stop() }
}

/// Runs a `MockWorld` against the real clock and serves its changes as a pull-based stream.
///
/// - A single loop task sleeps until the next scheduled event, so nothing runs while
///   nothing is due.
/// - Changes accumulate as a set of dirty task ids. The stream is built with
///   `AsyncStream(unfolding:)`: each `next()` waits for changes, then for 16 ms since the
///   previous batch, then snapshots the dirty tasks. There is no buffer, so a slow consumer
///   gets one merged, up-to-date batch instead of a backlog.
actor MockSimulator {
    /// Minimum real time between two batches.
    static let frameInterval: Duration = .milliseconds(16)
    /// Events due within this much real time are processed in the same wakeup.
    private static let lookahead = 0.010

    private let scenario: MockAgentSource.Scenario
    private let seed: UInt64
    private let speed: Double
    private let requestedStart: Date?
    private let clock = ContinuousClock()

    private var world: MockWorld?
    private var origin: ContinuousClock.Instant
    private var loop: Task<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var lastEmission: ContinuousClock.Instant?
    private var stream: AsyncStream<DeckUpdate>?
    private var stopped = false

    init(scenario: MockAgentSource.Scenario, seed: UInt64, speed: Double, startDate: Date?) {
        self.scenario = scenario
        self.seed = seed
        self.speed = speed
        self.requestedStart = startDate
        origin = clock.now
    }

    deinit { loop?.cancel() }

    /// Starts the simulation on the first call and returns its stream; later calls return
    /// the same stream (single consumer).
    func updates() -> AsyncStream<DeckUpdate> {
        if let stream { return stream }
        guard !stopped else {
            let finished = AsyncStream<DeckUpdate> { $0.finish() }
            stream = finished
            return finished
        }
        world = MockWorld(scenario: scenario, seed: seed, startDate: requestedStart ?? Date())
        origin = clock.now
        loop = Task { [weak self] in
            while let deadline = await self?.tick() {
                try? await Task.sleep(until: deadline, tolerance: .milliseconds(2), clock: .continuous)
                if Task.isCancelled { return }
            }
        }
        // Weak, so a dropped source (or stream) never keeps the other alive.
        let stream = AsyncStream(unfolding: { [weak self] in await self?.next() })
        self.stream = stream
        return stream
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        loop?.cancel()
        loop = nil
        world = nil
        waiter?.resume(returning: false)
        waiter = nil
    }

    // MARK: Simulation loop

    /// Processes due events and returns when to wake next (nil = stop).
    private func tick() -> ContinuousClock.Instant? {
        guard !stopped, let world else { return nil }
        let now = clock.now
        world.advance(to: simTime(at: now) + Self.lookahead * speed)
        if world.hasChanges, let waiter {
            self.waiter = nil
            waiter.resume(returning: true)
        }
        guard let next = world.nextEventTime else { return now + .seconds(3600) }
        return origin + .seconds(next / speed)
    }

    private func simTime(at instant: ContinuousClock.Instant) -> Double {
        let c = (instant - origin).components
        return (Double(c.seconds) + Double(c.attoseconds) * 1e-18) * speed
    }

    // MARK: Stream

    private func next() async -> DeckUpdate? {
        while !stopped, let world {
            // The first batch (the initial load) goes out immediately, even if empty.
            guard let last = lastEmission else {
                lastEmission = clock.now
                var update = world.takeUpdate()
                update.health = .ok
                return update
            }
            if world.hasChanges {
                let due = last + Self.frameInterval
                if clock.now < due {
                    try? await Task.sleep(until: due, clock: .continuous)
                    if Task.isCancelled { return nil }
                    continue
                }
                lastEmission = clock.now
                return world.takeUpdate()
            }
            guard await waitForChanges() else { return nil }
        }
        return nil
    }

    /// Suspends until the loop reports changes. False when stopped or cancelled.
    private func waitForChanges() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if stopped || Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiter?.resume(returning: true)
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    private func cancelWaiter() {
        waiter?.resume(returning: false)
        waiter = nil
    }
}
