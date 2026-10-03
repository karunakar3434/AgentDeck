import SwiftUI
import AgentDeckCore

/// Task detail: header, agent tree, live timeline.
struct TaskDetailView: View {
    var task: TaskModel
    var namespace: Namespace.ID

    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                section("Agents", symbol: "person.3.sequence.fill") {
                    AgentTree(task: task)
                }
                section("Timeline", symbol: "chart.bar.xaxis") {
                    TimelineChart(task: task)
                        .padding(.top, 6)
                }
            }
            .padding(18)
        }
        .background {
            RoundedRectangle(cornerRadius: 0)
                .fill(.background)
                .matchedGeometryEffect(id: "card-\(task.id)", in: namespace)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusPill(status: task.status)
                Spacer()
                TaskElapsedText(task: task, font: .system(.title3, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(task.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .matchedGeometryEffect(id: "title-\(task.id)", in: namespace, properties: .position)
            HStack(spacing: 10) {
                Label(task.projectName, systemImage: "folder")
                if let branch = task.gitBranch, !branch.isEmpty, branch != "HEAD" {
                    Label(branch, systemImage: "arrow.triangle.branch")
                }
                ModelBadge(model: task.mainModel)
                Spacer(minLength: 0)
                TaskETAText(task: task)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func section<C: View>(_ title: String, symbol: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .padding(10)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        }
    }
}

struct StatusPill: View {
    var status: TaskStatus
    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.14), in: .capsule)
            .contentTransition(.symbolEffect(.replace))
    }
}

struct RunStatusPill: View {
    var status: RunStatus
    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.14), in: .capsule)
            .contentTransition(.symbolEffect(.replace))
    }
}
