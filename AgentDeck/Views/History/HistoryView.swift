import SwiftUI
import AgentDeckCore

/// Tasks that finished within the history window, with actual vs estimated durations.
struct HistoryView: View {
    var taskIDs: [String]
    var namespace: Namespace.ID

    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        if taskIDs.isEmpty {
            ContentUnavailableView {
                Label("No finished tasks", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(nav.filters.isEmpty && nav.searchText.isEmpty
                     ? "Tasks that finish show up here with their actual and estimated times."
                     : "No finished tasks match the current filters.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: .sectionHeaders) {
                        ForEach(groups, id: \.title) { group in
                            Section {
                                ForEach(group.ids, id: \.self) { id in
                                    if let task = store.tasks[id] {
                                        HistoryRow(task: task, isHighlighted: nav.highlightedTaskID == id)
                                            .id(id)
                                            .contentShape(.rect)
                                            .onTapGesture { nav.openTask(id) }
                                    }
                                }
                            } header: {
                                Text(group.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .background(.background)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .animation(Theme.spring, value: taskIDs)
                .onChange(of: nav.highlightedTaskID) { _, id in
                    if let id { withAnimation(Theme.snappy) { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private var groups: [(title: String, ids: [String])] {
        let cal = Calendar.current
        var today: [String] = [], yesterday: [String] = [], older: [String] = []
        for id in taskIDs {
            guard let t = store.tasks[id] else { continue }
            let d = t.endedAt ?? t.lastActivityAt
            if cal.isDateInToday(d) { today.append(id) }
            else if cal.isDateInYesterday(d) { yesterday.append(id) }
            else { older.append(id) }
        }
        return [("Today", today), ("Yesterday", yesterday), ("Earlier", older)].filter { !$0.ids.isEmpty }
    }
}

private struct HistoryRow: View {
    var task: TaskModel
    var isHighlighted: Bool
    @Environment(DeckStore.self) private var store

    var body: some View {
        let runs = store.runs(of: task).filter { !$0.isMain }
        let over = runs.filter { r in r.estimate.map { r.elapsed(at: r.endedAt ?? task.lastActivityAt) > $0.seconds } ?? false }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: task.status.symbol)
                    .foregroundStyle(task.status.color)
                Text(task.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(DurationText.short(task.elapsed(at: task.endedAt ?? task.lastActivityAt)))
                    .font(Theme.smallTimerFont)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label(task.projectName, systemImage: "folder")
                    .lineLimit(1)
                if !runs.isEmpty {
                    Label("\(runs.count) agent\(runs.count == 1 ? "" : "s")", systemImage: "person.2")
                }
                if over > 0 {
                    Label("\(over) over estimate", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                Text(task.endedAt ?? task.lastActivityAt, format: .dateTime.hour().minute())
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(runs.prefix(6)) { run in
                        ActualVsEstimateBar(run: run, fallbackEnd: task.lastActivityAt)
                    }
                    if runs.count > 6 {
                        Text("+ \(runs.count - 6) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .drawingGroup()
        .background(isHighlighted ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
    }
}

/// "Explore  ███████░░░  1m 10s / ~1m"
struct ActualVsEstimateBar: View {
    var run: RunModel
    var fallbackEnd: Date

    var body: some View {
        let actual = run.elapsed(at: run.endedAt ?? fallbackEnd)
        let est = run.estimate?.seconds
        let scale = max(actual, est ?? 0, 1)
        HStack(spacing: 8) {
            Text(run.agentType)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            let width: CGFloat = 160
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let est {
                    Capsule()
                        .strokeBorder(.secondary.opacity(0.6), style: .init(lineWidth: 1, dash: [2, 2]))
                        .frame(width: width * est / scale)
                }
                Capsule()
                    .fill((est.map { actual > $0 } ?? false) ? Color.orange : run.status.color)
                    .frame(width: max(3, width * actual / scale))
            }
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 6)
            Text("\(DurationText.short(actual))\(est.map { " / \(run.estimate!.isApproximate ? "~" : "")\(DurationText.short($0))" } ?? "")")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
                .lineLimit(1)
        }
    }
}
