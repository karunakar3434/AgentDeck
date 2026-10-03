import AppKit
import QuartzCore

/// Measures main-thread frame pacing with a display link: every gap longer than one
/// refresh interval means the main thread missed at least one frame.
@MainActor
final class FrameMeter: NSObject {
    static let shared = FrameMeter()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var deltas: [Double] = []
    private var interval: Double = 1.0 / 60

    func start(in view: NSView) {
        stopLink()
        deltas.removeAll(keepingCapacity: true)
        last = 0
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        if l.duration > 0 { interval = l.duration }
        if last > 0 { deltas.append(l.timestamp - last) }
        last = l.timestamp
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    /// Stops and returns a one-line report.
    func stop() -> String {
        stopLink()
        guard !deltas.isEmpty else { return "frames=0" }
        let ms = deltas.map { $0 * 1000 }.sorted()
        let frameMs = interval * 1000
        let over = { (t: Double) in ms.filter { $0 > t }.count }
        let p = { (q: Double) in ms[min(ms.count - 1, Int(Double(ms.count) * q))] }
        let total = ms.reduce(0, +) / 1000
        // Hitches are judged against a 60 Hz budget (the target), whatever the display's rate.
        return String(format: "frames=%d secs=%.1f refresh=%.1fms gaps>25ms=%d gaps>50ms=%d gaps>100ms=%d p50=%.1f p99=%.1f max=%.1f",
                      ms.count, total, frameMs, over(25), over(50), over(100), p(0.5), p(0.99), ms.last!)
    }
}
