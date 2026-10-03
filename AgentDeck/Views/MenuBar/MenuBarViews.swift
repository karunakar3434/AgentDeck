import SwiftUI
import AgentDeckCore
import AgentDeckState

/// The menu bar item's label: a glyph and the running-agent count.
struct MenuBarLabel: View {
    @Environment(DeckStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.menuBarCount) private var showCount = true

    var body: some View {
        let n = Experiments.has("nomenubar") ? 0 : store.glanceRunningCount
        HStack(spacing: 3) {
            Image(systemName: n > 0 ? "square.stack.3d.up.fill" : "square.stack.3d.up")
            if showCount && n > 0 {
                Text("\(n)").monospacedDigit()
            }
        }
        .accessibilityLabel(n == 0 ? "AgentDeck, no agents running" : "AgentDeck, \(n) agents running")
        .onAppear { app.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Compact popover listing running agents with their progress.
struct MenuBarPopover: View {
    private static let maxRows = 40
    private static let rowHeight: CGFloat = 58
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Running agents")
                    .font(.headline)
                Spacer()
                Text("\(store.runningAgentCount)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(store.runningAgentCount)))
                    .animation(Theme.spring, value: store.runningAgentCount)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if store.runningRunIDs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "moon.stars")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No agents running")
                        .font(.callout.weight(.medium))
                    if let last = store.lastFinishedAt {
                        HStack(spacing: 3) {
                            Text("Last task finished")
                            AgoText(date: last)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                // Longest-running first; capped so the popover stays light with hundreds of agents.
                let shown = Array(store.runningRunIDs.prefix(Self.maxRows)).compactMap { store.runs[$0] }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { run in
                            PopoverRunRow(run: run, taskTitle: store.tasks[run.taskID]?.title ?? "")
                                .contentShape(.rect)
                                .onTapGesture { open(run) }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if store.runningRunIDs.count > Self.maxRows {
                            Text("and \(store.runningRunIDs.count - Self.maxRows) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 6)
                    .animation(Theme.spring, value: shown.map(\.id))
                }
                .frame(height: min(380, CGFloat(shown.count) * Self.rowHeight + 8))
            }

            Divider().padding(.top, 4)
            HStack {
                Button("Open AgentDeck") { openMain() }
                    .buttonStyle(.borderless)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 340)
        .pulseHost()
        .background { ClockDriver(isActive: store.isLive) }
    }

    private func open(_ run: RunModel) {
        if let task = store.tasks[run.taskID] { nav.section = task.status.isActive ? .active : .history }
        nav.inspect(run.id, in: run.taskID)
        openMain()
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct PopoverRunRow: View {
    var run: RunModel
    var taskTitle: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(run: run, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(run.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ElapsedText(run: run, font: Theme.smallTimerFont)
                        .foregroundStyle(.secondary)
                }
                Text(run.isMain ? taskTitle : run.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !run.isMain {
                    HStack(spacing: 6) {
                        RunProgressBar(run: run, height: 3)
                        EstimateText(run: run)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .drawingGroup()
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}
