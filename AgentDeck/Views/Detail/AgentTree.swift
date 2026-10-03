import SwiftUI
import AgentDeckCore

/// Main agent, its subagents, then nested subagents, as an indented tree.
struct AgentTree: View {
    var task: TaskModel
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        let ordered = orderedRuns()
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ordered, id: \.id) { run in
                AgentRow(run: run, isSelected: nav.inspectedRunID == run.id && nav.showInspector)
                    .padding(.leading, CGFloat(run.depth) * 18)
                    .contentShape(.rect)
                    .onTapGesture { nav.inspect(run.id, in: task.id) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: ordered.map(\.id))
    }

    /// Depth-first order: each run followed by its children, children in start order.
    private func orderedRuns() -> [RunModel] {
        let all = store.runs(of: task)
        var children: [String: [RunModel]] = [:]
        var roots: [RunModel] = []
        let ids = Set(all.map(\.id))
        for r in all {
            if let p = r.parentRunID, ids.contains(p) { children[p, default: []].append(r) } else { roots.append(r) }
        }
        var out: [RunModel] = []
        out.reserveCapacity(all.count)
        func visit(_ r: RunModel) {
            out.append(r)
            for c in (children[r.id] ?? []).sorted(by: { $0.startedAt < $1.startedAt }) { visit(c) }
        }
        for r in roots.sorted(by: { ($0.isMain ? 0 : 1, $0.startedAt) < ($1.isMain ? 0 : 1, $1.startedAt) }) { visit(r) }
        return out
    }
}

/// One agent in the tree: avatar, type, description, model, activity, timing.
struct AgentRow: View {
    var run: RunModel
    var isSelected: Bool
    @Environment(DeckStore.self) private var store
    @State private var hovering = false

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
                    ModelBadge(model: run.model, parentModel: store.tasks[run.taskID]?.mainModel, compact: true)
                    if run.isBackground {
                        Image(systemName: "moon.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Running in the background")
                    }
                }
                Text(run.isMain ? (store.tasks[run.taskID]?.title ?? "") : run.description)
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
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .drawingGroup()
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.05) : .clear))
        }
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: isSelected)
    }
}
