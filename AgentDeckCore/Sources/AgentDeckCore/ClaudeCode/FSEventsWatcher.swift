import CoreServices
import Foundation
import os

/// One file-system change reported by FSEvents.
struct FSChange: Sendable, Hashable {
    var path: String
    var flags: UInt32 = 0

    /// The kernel or the stream lost events, or a watched root changed: a full sweep is needed.
    var needsFullSweep: Bool {
        let mask = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                          | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        return flags & mask != 0
    }

    var isRemoved: Bool { flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 }
    var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
}

/// An `FSEventStream` over a set of directories, delivered as batches on an `AsyncStream` (architecture §4).
/// File-level events, no defer, watch-root, 0.1 s latency, events since now, on a private serial queue.
final class FSEventsWatcher: @unchecked Sendable {
    // @unchecked: `stream` is only touched on `queue` (start/stop hop onto it synchronously).
    private static let logger = Logger(subsystem: "com.karun.AgentDeck", category: "FSEvents")

    let paths: [String]
    let changes: AsyncStream<[FSChange]>
    private let continuation: AsyncStream<[FSChange]>.Continuation
    private let queue = DispatchQueue(label: "com.karun.AgentDeck.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: TimeInterval = 0.1) {
        self.paths = paths
        (changes, continuation) = AsyncStream.makeStream(of: [FSChange].self, bufferingPolicy: .unbounded)
        self.latency = latency
    }

    private let latency: TimeInterval

    /// Starts watching. False when the stream couldn't be created or started.
    func start() -> Bool {
        queue.sync {
            guard stream == nil, !paths.isEmpty else { return stream != nil }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<FSEventsWatcher>.fromOpaque(info).retain()
                    return UnsafeRawPointer(info)
                },
                release: { info in
                    guard let info else { return }
                    Unmanaged<FSEventsWatcher>.fromOpaque(info).release()
                },
                copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                                 | kFSEventStreamCreateFlagWatchRoot)
            guard let ref = FSEventStreamCreate(kCFAllocatorDefault, FSEventsWatcher.callback, &context,
                                                paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                latency, flags)
            else {
                Self.logger.error("FSEventStreamCreate failed")
                return false
            }
            FSEventStreamSetDispatchQueue(ref, queue)
            guard FSEventStreamStart(ref) else {
                FSEventStreamInvalidate(ref)
                FSEventStreamRelease(ref)
                Self.logger.error("FSEventStreamStart failed")
                return false
            }
            stream = ref
            return true
        }
    }

    /// Stops the stream and finishes `changes`. Idempotent.
    func stop() {
        queue.sync {
            if let ref = stream {
                FSEventStreamStop(ref)
                FSEventStreamInvalidate(ref)
                FSEventStreamRelease(ref)
                stream = nil
            }
        }
        continuation.finish()
    }

    fileprivate func deliver(_ batch: [FSChange]) {
        continuation.yield(batch)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var batch: [FSChange] = []
        batch.reserveCapacity(count)
        for i in 0..<count {
            batch.append(FSChange(path: String(cString: paths[i]), flags: eventFlags[i]))
        }
        watcher.deliver(batch)
    }
}
