import SwiftUI
import AgentDeckCore

/// Status and model colors, typography and motion used across the app.
enum Theme {
    // MARK: Motion

    /// The app's standard spring (~0.25s), or a short cross-fade with Reduce Motion on.
    static var spring: Animation { ReduceMotion.isOn ? .easeInOut(duration: 0.12) : .spring(duration: 0.25, bounce: 0.12) }
    static var snappy: Animation { ReduceMotion.isOn ? .easeInOut(duration: 0.1) : .snappy(duration: 0.2) }

    // MARK: Type

    static let timerFont = Font.system(.callout, design: .monospaced).monospacedDigit()
    static let smallTimerFont = Font.system(.caption, design: .monospaced).monospacedDigit()
    static let toolFont = Font.system(.caption, design: .monospaced)
}

extension TaskStatus {
    var color: Color {
        switch self {
        case .running: .blue
        case .waiting: .orange
        case .idle: .secondary
        case .done: .green
        case .failed: .red
        }
    }

    var symbol: String {
        switch self {
        case .running: "circle.dotted.circle"
        case .waiting: "hand.raised.fill"
        case .idle: "moon.zzz.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
}

extension RunStatus {
    var color: Color {
        switch self {
        case .queued: .secondary
        case .running: .blue
        case .done: .green
        case .failed: .red
        case .cancelled: .gray
        }
    }

    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "slash.circle"
        }
    }
}

extension ModelFamily {
    /// One distinct hue per model family.
    var color: Color {
        switch self {
        case .fable: .pink
        case .opus: .purple
        case .sonnet: .indigo
        case .haiku: .teal
        case .other: .gray
        }
    }
}

/// Cached system Reduce Motion flag, kept current via NSWorkspace notifications.
@MainActor
enum ReduceMotion {
    private(set) static var isOn = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private static let observer: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { isOn = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }

    static func startObserving() { _ = observer }
}
