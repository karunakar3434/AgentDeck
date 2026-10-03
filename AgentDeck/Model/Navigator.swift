import SwiftUI
import AgentDeckCore

enum SidebarSection: Hashable, Codable {
    case active
    case history
    case project(String)

    var title: String {
        switch self {
        case .active: "Active"
        case .history: "History"
        case .project(let name): name
        }
    }
}

struct Filters: Equatable {
    var projects: Set<String> = []
    var taskStatuses: Set<TaskStatus> = []
    var models: Set<ModelFamily> = []
    var agentTypes: Set<String> = []

    var isEmpty: Bool { projects.isEmpty && taskStatuses.isEmpty && models.isEmpty && agentTypes.isEmpty }
    var count: Int { projects.count + taskStatuses.count + models.count + agentTypes.count }
}

/// Window navigation and selection state.
@MainActor @Observable
final class Navigator {
    var section: SidebarSection = .active
    /// The task whose detail view is open, if any.
    var openTaskID: String?
    /// The run shown in the inspector.
    var inspectedRunID: String?
    var showInspector = false
    var showPalette = false
    var searchText = ""
    var isSearchFocused = false
    var filters = Filters()
    /// Keyboard highlight in lists (arrow keys), separate from the open task.
    var highlightedTaskID: String?

    func openTask(_ id: String) {
        withAnimation(Theme.spring) {
            openTaskID = id
            highlightedTaskID = id
        }
    }

    func closeTask() {
        withAnimation(Theme.spring) { openTaskID = nil }
    }

    func inspect(_ runID: String, in taskID: String) {
        if openTaskID != taskID { openTask(taskID) }
        withAnimation(Theme.spring) {
            inspectedRunID = runID
            showInspector = true
        }
    }

    func show(_ section: SidebarSection) {
        withAnimation(Theme.spring) {
            self.section = section
            openTaskID = nil
        }
    }
}
