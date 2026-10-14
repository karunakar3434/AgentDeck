import SwiftUI
import AgentDeckCore
import AgentDeckState

struct MainWindow: View {
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(AppModel.self) private var app
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var isNarrow = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
        } detail: {
            DetailContainer()
                // Wide windows: a trailing inspector column. Narrow windows (beside an editor):
                // the inspector slides over the detail instead of squeezing it.
                .inspector(isPresented: Binding(get: { inspectorShown && !isNarrow },
                                                set: { nav.showInspector = $0 })) {
                    InspectorView()
                }
                .overlay(alignment: .trailing) {
                    if isNarrow && inspectorShown {
                        NarrowInspector()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(Theme.spring, value: nav.showInspector)
        }
        .searchable(text: $nav.searchText, isPresented: $nav.isSearchFocused, placement: .toolbar, prompt: "Search tasks and agents")
        .toolbar { MainToolbar() }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .background { ClockDriver(isActive: store.isLive) }
        .overlay { CommandPaletteHost() }
        .frame(minWidth: 420, minHeight: 420)
        .onAppear {
            app.openMainWindow = { openWindow(id: "main") }
            app.openSettingsWindow = { openSettings() }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 640 } action: { narrow in
            // Collapse the sidebar beside an editor; bring it back when there's room.
            guard narrow != isNarrow else { return }
            isNarrow = narrow
            withAnimation(Theme.spring) { columnVisibility = narrow ? .detailOnly : .automatic }
        }
    }

    /// Only beside an open task: there's nothing to inspect in a list.
    private var inspectorShown: Bool { nav.showInspector && nav.openTaskID != nil }

    private var title: String {
        if let id = nav.openTaskID, let t = store.tasks[id] { return t.projectName }
        return nav.section.title
    }

    private var subtitle: String {
        if Experiments.has("nosubtitle") { return "" }
        if app.isMock { return "Simulated agents" }
        let n = store.glanceRunningCount
        return n == 0 ? "No agents running" : "\(n) agent\(n == 1 ? "" : "s") running"
    }
}

/// Switches between the list for the current section and an open task's detail.
private struct DetailContainer: View {
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Namespace private var namespace
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            if let id = nav.openTaskID, let task = store.tasks[id] {
                TaskDetailView(task: task, namespace: namespace)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                    .zIndex(1)
            } else {
                // The filtered list is computed in its own view, so this container (focus,
                // keys, the open task) doesn't depend on it.
                SectionList(namespace: namespace)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .defaultFocus($focused, true)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) {
            guard nav.openTaskID == nil else { return .ignored }
            let ids = visibleIDs()
            let highlighted = nav.highlightedTaskID.flatMap { ids.contains($0) ? $0 : nil }
            if let id = highlighted ?? ids.first { nav.openTask(id); return .handled }
            return .ignored
        }
        .onKeyPress(.escape) {
            if nav.showInspector && nav.openTaskID != nil { nav.hideInspector(); return .handled }
            if nav.openTaskID != nil { nav.closeTask(); return .handled }
            return .ignored
        }
        .onChange(of: nav.showPalette) { _, shown in if !shown { focused = true } }
        .onChange(of: nav.openTaskID) { focused = true }
    }

    /// The task ids currently listed, computed on demand (not a body dependency).
    private func visibleIDs() -> [String] {
        TaskQuery.ids(for: nav.section, store: store, nav: nav)
    }

    /// Arrow keys: move the highlight in lists, or between agents in an open task.
    private func move(_ delta: Int) {
        if let open = nav.openTaskID, let task = store.tasks[open] {
            let runs = task.runsInTreeOrder.map(\.id)
            guard !runs.isEmpty else { return }
            let i = nav.inspectedRunID.flatMap { runs.firstIndex(of: $0) } ?? (delta > 0 ? -1 : runs.count)
            let next = runs[max(0, min(runs.count - 1, i + delta))]
            nav.inspect(next, in: open)
            return
        }
        let ids = visibleIDs()
        guard !ids.isEmpty else { return }
        // A stale highlight from another section starts from the top or bottom.
        let i = nav.highlightedTaskID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        withAnimation(Theme.snappy) { nav.highlightedTaskID = ids[max(0, min(ids.count - 1, i + delta))] }
    }
}

/// The list for the current sidebar section, filters and search.
private struct SectionList: View {
    var namespace: Namespace.ID
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        let tasks = TaskQuery.tasks(for: nav.section, store: store, nav: nav)
        switch nav.section {
        case .active:
            ActiveView(tasks: tasks, namespace: namespace)
        case .history:
            HistoryView(tasks: tasks, namespace: namespace)
        case .project(let name):
            ProjectView(name: name, tasks: tasks, namespace: namespace)
        }
    }
}

/// A project's tasks: active ones as cards, then its history.
private struct ProjectView: View {
    var name: String
    var tasks: [TaskModel]
    var namespace: Namespace.ID

    var body: some View {
        let active = tasks.filter { $0.status.isActive }
        let done = tasks.filter { !$0.status.isActive }
        if active.isEmpty {
            HistoryView(tasks: done, namespace: namespace)
        } else if done.isEmpty {
            ActiveView(tasks: active, namespace: namespace, project: name)
        } else {
            VSplitView {
                ActiveView(tasks: active, namespace: namespace, project: name)
                HistoryView(tasks: done, namespace: namespace)
            }
        }
    }
}

/// The inspector as a sliding panel, used when the window is too narrow for a column.
private struct NarrowInspector: View {
    @Environment(Navigator.self) private var nav

    var body: some View {
        InspectorView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .overlay(alignment: .topTrailing) {
                Button {
                    nav.hideInspector()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(10)
                .help("Close the inspector (Esc)")
            }
    }
}
