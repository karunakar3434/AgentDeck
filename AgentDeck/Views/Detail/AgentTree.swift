import SwiftUI
import AgentDeckCore
import AgentDeckState

/// Main agent, its subagents, then nested subagents, as an indented tree.
struct AgentTree: View {
    var task: TaskModel
    @Environment(Navigator.self) private var nav

    var body: some View {
        let ordered = task.runsInTreeOrder
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(ordered, id: \.id) { run in
                AgentRow(run: run, task: task, isSelected: nav.inspectedRunID == run.id && nav.showInspector)
                    .padding(.leading, CGFloat(run.depth) * 18)
                    .contentShape(.rect)
                    .onTapGesture { nav.inspect(run.id, in: task.id) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: ordered.map(\.id))
        .pulseHost()
    }
}

/// One agent in the tree: avatar, type, description, model, activity, timing.
struct AgentRow: View {
    var run: RunModel
    var task: TaskModel
    var isSelected: Bool
    @State private var hovering = false

    private static let timingWidth: CGFloat = 104

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if run.depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            AgentAvatar(run: run, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    ModelBadge(model: run.model, parentModel: task.mainModel, compact: true)
                    if run.isBackground {
                        Image(systemName: "moon.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Running in the background")
                    }
                }
                Text(run.isMain ? task.title : run.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let activity = run.currentActivity, run.status == .running {
                    Text(activity)
                        .font(Theme.toolFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: Self.timingWidth, height: 1)   // room for the timing overlay
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .transaction { $0.animation = nil }
        // Live rows: flatten so a status or activity change redraws one GPU-backed layer;
        // the once-a-second timing column stays outside it.
        .drawingGroup()
        .overlay(alignment: .trailing) {
            RunTimingColumn(run: run)
                .frame(width: Self.timingWidth, alignment: .trailing)
                .padding(.trailing, 8)
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.05) : .clear))
        }
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: isSelected)
    }
}

/// Elapsed, progress ring and estimate for a run (clock-driven).
private struct RunTimingColumn: View {
    var run: RunModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                ElapsedText(run: run, font: Theme.smallTimerFont)
                if !run.isMain {
                    RunProgressRing(run: run, size: 16, lineWidth: 2.5)
                }
            }
            if !run.isMain {
                EstimateText(run: run)
            }
        }
    }
}
