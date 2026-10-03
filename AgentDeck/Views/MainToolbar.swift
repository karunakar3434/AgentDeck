import SwiftUI
import AgentDeckCore

struct MainToolbar: ToolbarContent {
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if nav.openTaskID != nil {
                Button {
                    nav.closeTask()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .help("Back to \(nav.section.title) (Esc)")
                .transition(.opacity)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            FilterMenu()

            Button {
                withAnimation(Theme.spring) { nav.showPalette.toggle() }
            } label: {
                Label("Go to…", systemImage: "command")
            }
            .help("Jump to a task or agent (⌘K)")

            Button {
                withAnimation(Theme.spring) { nav.showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

struct FilterMenu: View {
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        @Bindable var nav = nav
        Menu {
            if !nav.filters.isEmpty {
                Button("Clear Filters") { withAnimation(Theme.spring) { nav.filters = Filters() } }
                Divider()
            }
            Menu("Project") {
                ForEach(store.projects, id: \.self) { p in
                    Toggle(p, isOn: binding(\.projects, p))
                }
            }
            Menu("Status") {
                ForEach(TaskStatus.allCases, id: \.self) { s in
                    Toggle(isOn: binding(\.taskStatuses, s)) { Label(s.label, systemImage: s.symbol) }
                }
            }
            Menu("Model") {
                ForEach(ModelFamily.allCases, id: \.self) { m in
                    Toggle(m.displayName, isOn: binding(\.models, m))
                }
            }
            Menu("Agent Type") {
                ForEach(store.agentTypes, id: \.self) { t in
                    Toggle(t, isOn: binding(\.agentTypes, t))
                }
            }
        } label: {
            Label("Filter", systemImage: nav.filters.isEmpty
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .badge(nav.filters.count)
        .help("Filter by project, status, model or agent type")
    }

    private func binding<T: Hashable>(_ kp: WritableKeyPath<Filters, Set<T>>, _ value: T) -> Binding<Bool> {
        Binding(
            get: { nav.filters[keyPath: kp].contains(value) },
            set: { on in
                withAnimation(Theme.spring) {
                    if on { nav.filters[keyPath: kp].insert(value) } else { nav.filters[keyPath: kp].remove(value) }
                }
            }
        )
    }
}
