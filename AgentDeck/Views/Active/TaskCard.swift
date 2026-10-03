import SwiftUI
import AgentDeckCore

/// One card per active task: title, project, elapsed, agent avatars, ETA.
struct TaskCard: View {
    var task: TaskModel
    var namespace: Namespace.ID
    var isHighlighted: Bool

    @Environment(DeckStore.self) private var store
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(color: task.status.color, pulsing: task.status == .running, size: 9)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(task.title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                    .matchedGeometryEffect(id: "title-\(task.id)", in: namespace, properties: .position)
                Spacer(minLength: 8)
                TaskElapsedText(task: task)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Label(task.projectName, systemImage: "folder")
                    .lineLimit(1)
                if let branch = task.gitBranch, !branch.isEmpty, branch != "HEAD" {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ModelBadge(model: task.mainModel, compact: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                AvatarStack(task: task)
                Spacer(minLength: 4)
                Group {
                if task.status == .waiting {
                    Label("Waiting on you", systemImage: "hand.raised.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    TaskETAText(task: task)
                }
                }
                .fixedSize()
                .layoutPriority(1)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
                .matchedGeometryEffect(id: "card-\(task.id)", in: namespace)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isHighlighted ? Color.accentColor : Color.primary.opacity(hovering ? 0.14 : 0.07),
                              lineWidth: isHighlighted ? 2 : 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.10 : 0.04), radius: hovering ? 8 : 3, y: hovering ? 3 : 1)
        .scaleEffect(hovering ? 1.005 : 1)
        .animation(Theme.snappy, value: hovering)
        .onHover { hovering = $0 }
        .contentShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// As many agent avatars as fit (up to 12), then "+N".
struct AvatarStack: View {
    var task: TaskModel

    var body: some View {
        let runs = task.runs
        ViewThatFits(in: .horizontal) {
            ForEach([12, 9, 6, 4], id: \.self) { limit in
                row(runs, limit: limit)
            }
        }
        .animation(Theme.spring, value: task.runIDs)
    }

    private func row(_ runs: [RunModel], limit: Int) -> some View {
        HStack(spacing: -4) {
            ForEach(runs.prefix(limit)) { run in
                AgentAvatar(run: run, size: 22, pulsing: false)
                    .transition(.scale.combined(with: .opacity))
            }
            if runs.count > limit {
                Text("+\(runs.count - limit)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 22)
                    .background(.quaternary, in: .capsule)
                    .padding(.leading, 8)
            }
        }
        .fixedSize()
    }
}
