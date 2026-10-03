import SwiftUI
import AgentDeckCore

struct MainWindow: View {
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(AppModel.self) private var app
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var isNarrow = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
        } detail: {
            DetailContainer()
                .inspector(isPresented: $nav.showInspector) {
                    InspectorView()
                }
        }
        .searchable(text: $nav.searchText, isPresented: $nav.isSearchFocused, placement: .toolbar, prompt: "Search tasks and agents")
        .toolbar { MainToolbar() }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .background { ClockDriver(isActive: store.runningAgentCount > 0 || !store.activeTaskIDs.isEmpty) }
        .overlay { CommandPaletteHost() }
        .frame(minWidth: 420, minHeight: 420)
        .onAppear { app.openMainWindow = { openWindow(id: "main") } }
        .onGeometryChange(for: Bool.self) { $0.size.width < 640 } action: { narrow in
            // Collapse the sidebar beside an editor; bring it back when there's room.
            guard narrow != isNarrow else { return }
            isNarrow = narrow
            withAnimation(Theme.spring) { columnVisibility = narrow ? .detailOnly : .automatic }
        }
    }

    private var title: String {
        if let id = nav.openTaskID, let t = store.tasks[id] { return t.projectName }
        return nav.section.title
    }

    private var subtitle: String {
        if app.isMock { return "Simulated agents" }
        let n = store.runningAgentCount
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
        let ids = TaskQuery.ids(for: nav.section, store: store, nav: nav)
        ZStack {
            if let id = nav.openTaskID, let task = store.tasks[id] {
                TaskDetailView(task: task, namespace: namespace)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                    .zIndex(1)
            } else {
                Group {
                    switch nav.section {
                    case .active:
                        ActiveView(taskIDs: ids, namespace: namespace)
                    case .history:
                        HistoryView(taskIDs: ids, namespace: namespace)
                    case .project(let name):
                        ProjectView(name: name, taskIDs: ids, namespace: namespace)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .defaultFocus($focused, true)
        .onKeyPress(.upArrow) { move(-1, in: ids); return .handled }
        .onKeyPress(.downArrow) { move(1, in: ids); return .handled }
        .onKeyPress(.return) {
            if nav.openTaskID == nil, let id = nav.highlightedTaskID ?? ids.first { nav.openTask(id); return .handled }
            return .ignored
        }
        .onKeyPress(.escape) {
            if nav.showInspector && nav.openTaskID != nil { withAnimation(Theme.spring) { nav.showInspector = false }; return .handled }
            if nav.openTaskID != nil { nav.closeTask(); return .handled }
            return .ignored
        }
        .onChange(of: nav.showPalette) { _, shown in if !shown { focused = true } }
        .onChange(of: nav.openTaskID) { focused = true }
    }

    /// Arrow keys: move the highlight in lists, or between agents in an open task.
    private func move(_ delta: Int, in ids: [String]) {
        if let open = nav.openTaskID, let task = store.tasks[open] {
            let runs = task.runIDs
            guard !runs.isEmpty else { return }
            let i = nav.inspectedRunID.flatMap { runs.firstIndex(of: $0) } ?? (delta > 0 ? -1 : runs.count)
            let next = runs[max(0, min(runs.count - 1, i + delta))]
            nav.inspect(next, in: open)
            return
        }
        guard !ids.isEmpty else { return }
        let i = nav.highlightedTaskID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        withAnimation(Theme.snappy) { nav.highlightedTaskID = ids[max(0, min(ids.count - 1, i + delta))] }
    }
}

/// A project's tasks: active ones as cards, then its history.
private struct ProjectView: View {
    var name: String
    var taskIDs: [String]
    var namespace: Namespace.ID
    @Environment(DeckStore.self) private var store

    var body: some View {
        let active = taskIDs.filter { store.tasks[$0]?.status.isActive == true }
        let done = taskIDs.filter { store.tasks[$0]?.status.isActive != true }
        if active.isEmpty {
            HistoryView(taskIDs: done, namespace: namespace)
        } else if done.isEmpty {
            ActiveView(taskIDs: active, namespace: namespace, project: name)
        } else {
            VSplitView {
                ActiveView(taskIDs: active, namespace: namespace, project: name)
                HistoryView(taskIDs: done, namespace: namespace)
            }
        }
    }
}
