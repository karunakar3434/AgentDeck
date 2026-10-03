import Foundation

/// Batches task changes into `DeckUpdate`s: at most one batch per `interval`, none while idle, and
/// lossless backpressure (architecture §10).
///
/// The dirty set, not the batch, is the source of truth. A batch the consumer hasn't taken yet makes the
/// next `yield` drop; the dirty ids stay marked and the caller retries, so the UI then receives one merged
/// batch with the latest snapshot of every changed task.
///
/// A plain value owned by one actor. Usage from the owner:
/// ```
/// if coalescer.markDirty(id) { scheduleFlush() }          // schedule = sleep `interval`, then flush
/// switch coalescer.flush(into: continuation, build: snapshot(for:)) {
/// case .retry: scheduleFlush()
/// case .terminated: stop()
/// case .emitted, .idle: break
/// }
/// ```
struct UpdateCoalescer: Sendable {
    enum FlushResult: Equatable, Sendable {
        /// Nothing changed; nothing was sent.
        case idle
        /// A batch was enqueued.
        case emitted
        /// The consumer hasn't taken the previous batch. State is kept; flush again after `interval`.
        case retry
        /// The stream is finished.
        case terminated
    }

    let interval: Duration
    private(set) var dirty: Set<String> = []
    private(set) var removed: Set<String> = []
    /// True between the first mark and the flush that consumes it.
    private(set) var flushPending = false
    /// Latest snapshot sent per task id.
    private(set) var lastEmitted: [String: TaskSnapshot] = [:]
    private(set) var initialLoadComplete = false
    private var loadCompletePending = false
    private var pendingHealth: SourceHealth?
    private(set) var batchesEmitted = 0

    init(interval: Duration = .milliseconds(16)) {
        self.interval = interval
    }

    /// Marks a task for rebuild. Returns true when the caller must schedule a flush.
    mutating func markDirty(_ id: String) -> Bool {
        dirty.insert(id)
        return requestFlush()
    }

    /// Marks a task as gone (sent in `removed` if it was ever emitted).
    mutating func markRemoved(_ id: String) -> Bool {
        dirty.remove(id)
        guard lastEmitted[id] != nil else { return false }
        removed.insert(id)
        return requestFlush()
    }

    /// Sets `initialLoadComplete` on this and every later batch; forces one batch even if nothing changed.
    mutating func markLoadComplete() -> Bool {
        guard !initialLoadComplete else { return false }
        initialLoadComplete = true
        loadCompletePending = true
        return requestFlush()
    }

    /// Reports a health change in the next batch.
    mutating func setHealth(_ health: SourceHealth) -> Bool {
        pendingHealth = health
        return requestFlush()
    }

    private mutating func requestFlush() -> Bool {
        guard !flushPending else { return false }
        flushPending = true
        return true
    }

    /// Builds and yields one batch. `build` returns the current snapshot of a dirty task, or nil when the
    /// task is out of scope (it is then sent as removed if the UI has it).
    mutating func flush(into continuation: AsyncStream<DeckUpdate>.Continuation?,
                        build: (String) -> TaskSnapshot?) -> FlushResult {
        var changed: [TaskSnapshot] = []
        var removedNow = removed
        for id in dirty {
            if let snapshot = build(id) {
                if lastEmitted[id] != snapshot { changed.append(snapshot) }
                removedNow.remove(id)
            } else if lastEmitted[id] != nil {
                removedNow.insert(id)
            }
        }
        guard !changed.isEmpty || !removedNow.isEmpty || loadCompletePending || pendingHealth != nil else {
            dirty.removeAll(keepingCapacity: true)
            removed.removeAll(keepingCapacity: true)
            flushPending = false
            return .idle
        }
        guard let continuation else {
            // No consumer yet: keep everything for the first real flush.
            flushPending = false
            return .idle
        }
        changed.sort { $0.id < $1.id }
        let update = DeckUpdate(changed: changed, removed: removedNow.sorted(),
                                initialLoadComplete: initialLoadComplete, health: pendingHealth)
        switch continuation.yield(update) {
        case .enqueued:
            for s in changed { lastEmitted[s.id] = s }
            for id in removedNow { lastEmitted[id] = nil }
            dirty.removeAll(keepingCapacity: true)
            removed.removeAll(keepingCapacity: true)
            loadCompletePending = false
            pendingHealth = nil
            flushPending = false
            batchesEmitted += 1
            return .emitted
        case .dropped:
            removed = removedNow
            return .retry
        case .terminated:
            flushPending = false
            return .terminated
        @unknown default:
            return .retry
        }
    }

    /// Forgets what was sent (for example after the consumer restarted).
    mutating func reset() {
        dirty = []
        removed = []
        lastEmitted = [:]
        flushPending = false
    }
}
