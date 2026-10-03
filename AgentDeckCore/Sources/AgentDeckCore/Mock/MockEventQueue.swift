import Foundation

/// Min-heap of timed events. Ties are broken by insertion order, so processing
/// order (and therefore the whole simulation) is deterministic.
struct MockEventQueue {
    private struct Entry {
        var time: Double
        var seq: UInt64
        var payload: MockEvent

        func precedes(_ other: Entry) -> Bool {
            time < other.time || (time == other.time && seq < other.seq)
        }
    }

    private var heap: [Entry] = []
    private var nextSeq: UInt64 = 0

    var isEmpty: Bool { heap.isEmpty }
    var count: Int { heap.count }
    var nextTime: Double? { heap.first?.time }

    mutating func push(_ payload: MockEvent, at time: Double) {
        let item = Entry(time: time, seq: nextSeq, payload: payload)
        nextSeq &+= 1
        heap.append(item)
        // Sift up by moving parents into the hole (raw pointers keep debug builds fast).
        heap.withUnsafeMutableBufferPointer { buffer in
            let h = buffer.baseAddress!
            var i = buffer.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard item.precedes(h[parent]) else { break }
                h[i] = h[parent]
                i = parent
            }
            h[i] = item
        }
    }

    /// Removes and returns the earliest event if it is due at or before `time`.
    mutating func pop(dueBy time: Double) -> (time: Double, payload: MockEvent)? {
        guard let first = heap.first, first.time <= time else { return nil }
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap.withUnsafeMutableBufferPointer { buffer in
                let h = buffer.baseAddress!
                let n = buffer.count
                var i = 0
                while true {
                    var child = 2 * i + 1
                    if child >= n { break }
                    if child + 1 < n, h[child + 1].precedes(h[child]) { child += 1 }
                    guard h[child].precedes(last) else { break }
                    h[i] = h[child]
                    i = child
                }
                h[i] = last
            }
        }
        return (first.time, first.payload)
    }
}
