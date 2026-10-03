import Foundation
import AgentDeckCore
import AgentDeckState

/// Applies sidebar section, filters and search text to the store's task lists.
@MainActor
enum TaskQuery {
    static func tasks(for section: SidebarSection, store: DeckStore, nav: Navigator) -> [TaskModel] {
        let base: [TaskModel]
        switch section {
        case .active:
            base = store.activeTasks
        case .history:
            base = store.inactiveTasks
        case .project(let name):
            base = (store.activeTasks + store.inactiveTasks).filter { $0.projectName == name }
        }
        return filter(base, filters: nav.filters, search: nav.searchText)
    }

    static func ids(for section: SidebarSection, store: DeckStore, nav: Navigator) -> [String] {
        tasks(for: section, store: store, nav: nav).map(\.id)
    }

    static func filter(_ tasks: [TaskModel], filters: Filters, search: String) -> [TaskModel] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if filters.isEmpty && q.isEmpty { return tasks }
        return tasks.filter { t in
            if !filters.projects.isEmpty && !filters.projects.contains(t.projectName) { return false }
            if !filters.taskStatuses.isEmpty && !filters.taskStatuses.contains(t.status) { return false }
            if !filters.models.isEmpty && Set(t.modelFamilies).isDisjoint(with: filters.models) { return false }
            if !filters.agentTypes.isEmpty && !t.runs.contains(where: { filters.agentTypes.contains($0.agentType) }) { return false }
            if !q.isEmpty {
                if t.title.lowercased().contains(q) || t.projectName.lowercased().contains(q) { return true }
                return t.runs.contains { $0.agentType.lowercased().contains(q) || $0.description.lowercased().contains(q) }
            }
            return true
        }
    }
}
