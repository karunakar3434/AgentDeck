import SwiftUI
import AgentDeckCore

// Leaf views that read Clock.shared.now. Keep time-dependent reads inside these
// so a clock tick redraws only them.

/// "1:42" elapsed for a run, rolling digits, fixed width.
struct ElapsedText: View {
    var run: RunModel
    var font: Font = Theme.timerFont

    var body: some View {
        let now = run.status.isFinished ? (run.endedAt ?? Clock.shared.now) : Clock.shared.now
        let secs = run.elapsed(at: now)
        Text(DurationText.clock(secs))
            .font(font)
            .contentTransition(.numericText(value: secs))
    }
}

/// "1:42" elapsed for a task.
struct TaskElapsedText: View {
    var task: TaskModel
    var font: Font = Theme.timerFont

    var body: some View {
        let secs = task.elapsed(at: Clock.shared.now)
        Text(DurationText.clock(secs))
            .font(font)
            .contentTransition(.numericText(value: secs))
    }
}

/// "of ~3m" / "over by 1m 20s" / "took 2m 10s · est 3m".
struct EstimateText: View {
    var run: RunModel

    var body: some View {
        let now = Clock.shared.now
        Group {
            if let est = run.estimate {
                let prefix = est.isApproximate ? "~" : ""
                if let over = run.overrun(at: now), !run.status.isFinished {
                    Text("over by \(DurationText.short(over))")
                        .foregroundStyle(.orange)
                } else if run.status.isFinished {
                    Text("est \(prefix)\(DurationText.short(est.seconds))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("of \(prefix)\(DurationText.short(est.seconds))")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("no estimate").foregroundStyle(.tertiary)
            }
        }
        .font(Theme.smallTimerFont)
        .lineLimit(1)
    }
}

/// Progress ring bound to the clock.
struct RunProgressRing: View {
    var run: RunModel
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5

    var body: some View {
        let now = Clock.shared.now
        let progress: Double? = run.status.isFinished ? 1 : run.progress(at: now)
        ProgressRing(
            progress: progress,
            color: run.status.color,
            isOver: !run.status.isFinished && run.overrun(at: now) != nil,
            lineWidth: lineWidth
        )
        .frame(width: size, height: size)
    }
}

/// Linear progress bar bound to the clock.
struct RunProgressBar: View {
    var run: RunModel
    var height: CGFloat = 4

    var body: some View {
        let now = Clock.shared.now
        let over = !run.status.isFinished && run.overrun(at: now) != nil
        ProgressBar(
            progress: run.status.isFinished ? 1 : (run.progress(at: now) ?? 0),
            color: over ? .orange : run.status.color,
            height: height
        )
    }
}

/// "ETA 2m 10s" for a task (slowest running subagent), or nothing.
struct TaskETAText: View {
    var task: TaskModel

    var body: some View {
        if let eta = task.eta {
            let remaining = eta.timeIntervalSince(Clock.shared.now)
            if remaining > 0 {
                Label("ETA \(DurationText.short(remaining))", systemImage: "flag.checkered")
                    .font(Theme.smallTimerFont)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: remaining))
            } else {
                Label("over by \(DurationText.short(-remaining))", systemImage: "flag.checkered")
                    .font(Theme.smallTimerFont)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// "4m ago" relative to the clock.
struct AgoText: View {
    var date: Date
    var body: some View {
        Text(DurationText.ago(Clock.shared.now.timeIntervalSince(date)))
    }
}
