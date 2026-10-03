import SwiftUI

/// The single source of "now" for every timer in the app.
///
/// One `ClockDriver` (a `TimelineView`) per window ticks this once a second while
/// anything is running, and every 30s otherwise (for "4m ago" labels). Views read
/// `clock.now` only inside the small leaf views that display time, so a tick
/// redraws timers and nothing else.
@MainActor @Observable
final class Clock {
    static let shared = Clock()
    private(set) var now = Date()

    func tick(_ date: Date) {
        // Whole-second granularity keeps text from re-rendering more than once a second.
        let t = date.timeIntervalSinceReferenceDate.rounded(.down)
        if t != now.timeIntervalSinceReferenceDate { now = Date(timeIntervalSinceReferenceDate: t) }
    }

    func sync() { tick(Date()) }
}

/// Drives `Clock.shared` from one `TimelineView`. Place once per window, behind content.
struct ClockDriver: View {
    var isActive: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: isActive ? 1 : 30)) { context in
            Color.clear
                .onChange(of: context.date, initial: true) { _, date in Clock.shared.tick(date) }
        }
        .id(isActive) // restart the schedule when the cadence changes
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
