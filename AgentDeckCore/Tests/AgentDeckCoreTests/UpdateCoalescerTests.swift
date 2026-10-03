import Foundation
import Testing
@testable import AgentDeckCore

@Suite struct UpdateCoalescerTests {
    private func task(_ id: String, title: String = "t", status: TaskStatus = .running) -> TaskSnapshot {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return TaskSnapshot(id: id, source: "test", projectName: "p", projectPath: "/p", title: title, status: status,
                            startedAt: date, lastActivityAt: date, endedAt: nil,
                            mainModel: ModelInfo(id: nil, source: .inherited), gitBranch: nil, runs: [])
    }

    @Test func firstMarkSchedulesLaterMarksDoNot() {
        var c = UpdateCoalescer()
        let first = c.markDirty("a")
        let second = c.markDirty("b")
        let third = c.markDirty("a")
        #expect(first)
        #expect(!second)
        #expect(!third)
        #expect(c.dirty == ["a", "b"])
    }

    @Test func unchangedSnapshotsAreNotResent() {
        var c = UpdateCoalescer()
        let (stream, continuation) = AsyncStream.makeStream(of: DeckUpdate.self, bufferingPolicy: .unbounded)
        withExtendedLifetime(stream) {
            _ = c.markDirty("a")
            let r1 = c.flush(into: continuation) { self.task($0) }
            _ = c.markDirty("a")
            let r2 = c.flush(into: continuation) { self.task($0) }      // same snapshot: nothing sent
            let pending = c.flushPending
            _ = c.markDirty("a")
            let r3 = c.flush(into: continuation) { self.task($0, status: .done) }
            #expect(r1 == .emitted)
            #expect(r2 == .idle)
            #expect(!pending)
            #expect(r3 == .emitted)
            #expect(c.batchesEmitted == 2)
        }
    }

    @Test func backpressureKeepsDirtyStateAndMergesTheNextBatch() async {
        var c = UpdateCoalescer()
        let (stream, continuation) = AsyncStream.makeStream(of: DeckUpdate.self, bufferingPolicy: .bufferingOldest(1))
        _ = c.markDirty("a")
        let r1 = c.flush(into: continuation) { self.task($0, title: "a1") }
        #expect(r1 == .emitted)
        // The UI hasn't taken the first batch: the next yield is dropped and the state is kept.
        _ = c.markDirty("a")
        _ = c.markDirty("b")
        let r2 = c.flush(into: continuation) { self.task($0, title: "\($0)2") }
        #expect(r2 == .retry)
        #expect(c.dirty == ["a", "b"])
        #expect(c.flushPending)
        _ = c.markDirty("c")
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.changed.map(\.title) == ["a1"])
        // One merged batch with the latest snapshot of every changed task.
        let r3 = c.flush(into: continuation) { self.task($0, title: "\($0)3") }
        #expect(r3 == .emitted)
        let merged = await iterator.next()
        #expect(merged?.changed.map(\.id) == ["a", "b", "c"])
        #expect(merged?.changed.map(\.title) == ["a3", "b3", "c3"])
    }

    @Test func removalOnlyForEmittedTasks() async {
        var c = UpdateCoalescer()
        let (stream, continuation) = AsyncStream.makeStream(of: DeckUpdate.self, bufferingPolicy: .unbounded)
        var iterator = stream.makeAsyncIterator()
        let neverSent = c.markRemoved("never-sent")
        #expect(!neverSent)
        _ = c.markDirty("a")
        _ = c.flush(into: continuation) { self.task($0) }
        _ = await iterator.next()
        // Out of scope on rebuild: removed.
        _ = c.markDirty("a")
        let r = c.flush(into: continuation) { _ in nil }
        #expect(r == .emitted)
        let update = await iterator.next()
        #expect(update?.removed == ["a"])
        #expect(c.lastEmitted["a"] == nil)
    }

    @Test func loadCompleteAndHealthForceOneBatch() async {
        var c = UpdateCoalescer()
        let (stream, continuation) = AsyncStream.makeStream(of: DeckUpdate.self, bufferingPolicy: .unbounded)
        var iterator = stream.makeAsyncIterator()
        let scheduled = c.markLoadComplete()
        #expect(scheduled)
        let r1 = c.flush(into: continuation) { _ in nil }
        #expect(r1 == .emitted)
        let done = await iterator.next()
        #expect(done?.initialLoadComplete == true)
        #expect(done?.isEmpty == true)
        _ = c.setHealth(.degraded("Data folder not found"))
        _ = c.flush(into: continuation) { _ in nil }
        let health = await iterator.next()
        #expect(health?.health == .degraded("Data folder not found"))
        #expect(health?.initialLoadComplete == true)
        _ = c.markDirty("x")
        let r2 = c.flush(into: continuation) { _ in nil }          // nothing to say
        #expect(r2 == .idle)
    }

    @Test func terminatedStream() {
        var c = UpdateCoalescer()
        let (_, continuation) = AsyncStream.makeStream(of: DeckUpdate.self)
        continuation.finish()
        _ = c.markDirty("a")
        let r = c.flush(into: continuation) { self.task($0) }
        #expect(r == .terminated)
    }
}
