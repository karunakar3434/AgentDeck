import Foundation
import AgentDeckCore

/// Applies sidebar section, filters and search text to the store's task lists.
@MainActor
enum TaskQuery {
    static func ids(for section: SidebarSection, store: DeckStore, nav: Navigator) -> [String] {
        let base: [String]
        switch section {
        case .active:
            base = store.activeTaskIDs
        case .history:
            base = store.inactiveTaskIDs
        case .project(let name):
            base = (store.activeTaskIDs + store.inactiveTaskIDs).filter { store.tasks[$0]?.projectName == name }
        }
        return filter(base, store: store, filters: nav.filters, search: nav.searchText)
    }

    static func filter(_ ids: [String], store: DeckStore, filters: Filters, search: String) -> [String] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if filters.isEmpty && q.isEmpty { return ids }
        return ids.filter { id in
            guard let t = store.tasks[id] else { return false }
            if !filters.projects.isEmpty && !filters.projects.contains(t.projectName) { return false }
            if !filters.taskStatuses.isEmpty && !filters.taskStatuses.contains(t.status) { return false }
            let runs = store.runs(of: t)
            if !filters.models.isEmpty {
                let fams = Set(runs.map { $0.model.id == nil ? t.mainModel.family : $0.model.family })
                if fams.isDisjoint(with: filters.models) { return false }
            }
            if !filters.agentTypes.isEmpty {
                if !runs.contains(where: { filters.agentTypes.contains($0.agentType) }) { return false }
            }
            if !q.isEmpty {
                if t.title.lowercased().contains(q) || t.projectName.lowercased().contains(q) { return true }
                return runs.contains { $0.agentType.lowercased().contains(q) || $0.description.lowercased().contains(q) }
            }
            return true
        }
    }
}
