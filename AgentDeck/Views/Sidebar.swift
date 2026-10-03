import SwiftUI
import AgentDeckCore
import AgentDeckState

struct Sidebar: View {
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        @Bindable var nav = nav
        if Experiments.has("nosidebar") { Color.clear } else {
        List(selection: Binding<SidebarSection?>(
            get: { nav.section },
            set: { if let s = $0 { nav.show(s) } }
        )) {
            Section {
                Label {
                    Text("Active")
                } icon: {
                    Image(systemName: "bolt.horizontal.circle.fill")
                }
                .badge(store.activeTaskIDs.count)
                .tag(SidebarSection.active)

                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarSection.history)
            }

            // Workflow groups in their configured order, folder projects A–Z, then Others.
            Section("Projects") {
                ForEach(store.projects, id: \.self) { name in
                    ProjectRow(name: name, kind: store.projectKind(of: name),
                               active: store.activeCountByProject[name] ?? 0)
                        .tag(SidebarSection.project(name))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        .animation(Theme.spring, value: store.projects)
        }
    }
}

private struct ProjectRow: View {
    var name: String
    var kind: ProjectKind
    var active: Int

    var body: some View {
        Label {
            Text(name).lineLimit(1)
        } icon: {
            Image(systemName: kind.symbol(filled: active > 0))
        }
        .badge(active)
    }
}
