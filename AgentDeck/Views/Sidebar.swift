import SwiftUI
import AgentDeckCore

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

            if !store.projects.isEmpty {
                Section("Projects") {
                    ForEach(store.projects, id: \.self) { name in
                        ProjectRow(name: name)
                            .tag(SidebarSection.project(name))
                    }
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
    @Environment(DeckStore.self) private var store

    var body: some View {
        let active = store.activeTaskIDs.reduce(0) { $0 + (store.tasks[$1]?.projectName == name ? 1 : 0) }
        Label {
            Text(name).lineLimit(1)
        } icon: {
            Image(systemName: active > 0 ? "folder.fill" : "folder")
        }
        .badge(active)
    }
}
