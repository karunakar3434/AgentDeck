import SwiftUI
import AgentDeckCore

/// Right-hand panel for one agent run.
struct InspectorView: View {
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        Group {
            if Experiments.has("noinspector") {
                Color.clear
            } else if let id = nav.inspectedRunID, let run = store.runs[id] {
                RunInspector(run: run)
                    .id(id)
                    .transition(.opacity)
            } else {
                ContentUnavailableView("No agent selected", systemImage: "sidebar.right",
                                       description: Text("Click an agent or a timeline bar to inspect it."))
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        .animation(Theme.spring, value: nav.inspectedRunID)
    }
}

private struct RunInspector: View {
    var run: RunModel
    @Environment(DeckStore.self) private var store
    @State private var showPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                timing
                if !run.isMain && !run.prompt.isEmpty { promptSection }
                if let summary = run.resultSummary, run.status.isFinished { resultSection(summary) }
                ToolFeed(run: run)
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentAvatar(run: run, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.displayName)
                        .font(.title3.weight(.semibold))
                    if let agentID = run.agentID {
                        Text(agentID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            if !run.isMain {
                Text(run.description)
                    .font(.body)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                RunStatusPill(status: run.status)
                ModelBadge(model: run.model, parentModel: store.tasks[run.taskID]?.mainModel)
                if run.isBackground {
                    Label("Background", systemImage: "moon.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                RunProgressRing(run: run, size: 44, lineWidth: 5)
                VStack(alignment: .leading, spacing: 2) {
                    ElapsedText(run: run, font: .system(.title2, design: .monospaced).monospacedDigit().weight(.semibold))
                    if !run.isMain { EstimateText(run: run) }
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Started").foregroundStyle(.secondary)
                    Text(run.startedAt, format: .dateTime.hour().minute().second())
                }
                if let end = run.endedAt {
                    GridRow {
                        Text("Ended").foregroundStyle(.secondary)
                        Text(end, format: .dateTime.hour().minute().second())
                    }
                }
                if let est = run.estimate, !run.isMain {
                    GridRow {
                        Text("Estimate").foregroundStyle(.secondary)
                        Text("\(est.isApproximate ? "~" : "")\(DurationText.short(est.seconds)) · \(est.confidence.rawValue) confidence (\(est.sampleCount) run\(est.sampleCount == 1 ? "" : "s"))")
                    }
                }
                GridRow {
                    Text("Tool calls").foregroundStyle(.secondary)
                    Text("\(run.toolCallCount)")
                        .contentTransition(.numericText(value: Double(run.toolCallCount)))
                        .animation(Theme.snappy, value: run.toolCallCount)
                }
                if let tokens = run.tokens, tokens.total > 0 {
                    GridRow {
                        Text("Tokens").foregroundStyle(.secondary)
                        Text("\(tokens.total.formatted(.number.notation(.compactName))) (\(tokens.output.formatted(.number.notation(.compactName))) out)")
                    }
                }
            }
            .font(.caption.monospacedDigit())
        }
        .padding(12)
        .drawingGroup()
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    private var promptSection: some View {
        DisclosureGroup(isExpanded: $showPrompt) {
            Text(run.prompt)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label("Prompt", systemImage: "text.quote")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func resultSection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Result", systemImage: run.status == .failed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(run.status == .failed ? .red : .green)
            Text(summary)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background((run.status == .failed ? Color.red : Color.green).opacity(0.07), in: .rect(cornerRadius: 12))
    }
}

/// Live feed of the run's tool calls, newest first.
private struct ToolFeed: View {
    var run: RunModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Tool calls", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
            if run.recentTools.isEmpty {
                Text(run.status == .running ? "Waiting for the first tool call…" : "No tool calls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(run.recentTools.reversed()) { tool in
                        ToolRow(tool: tool)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(Theme.spring, value: run.recentTools.last?.id)
            }
        }
    }
}

private struct ToolRow: View {
    var tool: ToolEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tool.isError ? .red : (tool.endedAt == nil ? .blue : .secondary))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                    .font(.caption.weight(.semibold))
                if !tool.summary.isEmpty {
                    Text(tool.summary)
                        .font(Theme.toolFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let end = tool.endedAt {
                Text(DurationText.short(end.timeIntervalSince(tool.startedAt)))
                    .font(Theme.smallTimerFont)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .drawingGroup()
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 6))
    }

    private var icon: String {
        switch tool.name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "Write": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        default: tool.name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench"
        }
    }
}
