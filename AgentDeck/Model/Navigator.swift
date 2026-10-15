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
    /// The run highlighted in the open task's tree and timeline: the inspected one, only while the inspector
    /// is up. Hiding it keeps `inspectedRunID`, so showing it again comes back to the same agent.
    var selectedRunID: String? { showInspector ? inspectedRunID : nil }
    var showPalette = false
    var searchText = ""
    var isSearchFocused = false
    var filters = Filters()
    /// Keyboard highlight in lists (arrow keys), separate from the open task.
    var highlightedTaskID: String?

    func openTask(_ id: String) {
        // Until the list has gone, an inspector request waits (see `presentInspector`).
        openingTask = id
        withAnimation(Theme.spring, completionCriteria: .removed) {
            enterTask(id)
        } completion: { [weak self] in
            guard let self, openingTask == id else { return }
            openingTask = nil
            if inspectorAfterOpening, openTaskID == id { moveInspector(shown: true, animated: true) }
            inspectorAfterOpening = false
        }
    }

    func closeTask() {
        leaveTask()
    }

    func inspect(_ runID: String, in taskID: String) {
        guard openTaskID == taskID else {
            // From a list: the task opens first and the inspector comes in after it.
            openTask(taskID)
            inspectedRunID = runID
            presentInspector()
            return
        }
        withAnimation(Theme.spring) { inspectedRunID = runID }
        presentInspector()
    }

    /// The toolbar button and ⌥⌘I. Does nothing without an open task — the inspector belongs to it.
    func toggleInspector() {
        guard openTaskID != nil else { return }
        if showInspector { hideInspector() } else { presentInspector() }
    }

    /// Esc, the toolbar, ⌥⌘I and the narrow inspector's × button.
    func hideInspector() {
        guard showInspector else { return }
        moveInspector(shown: false, animated: true)
    }

    func show(_ section: SidebarSection) {
        leaveTask { self.section = section }
    }

    /// A fresh start, when the data source changes.
    func reset() {
        pendingLeave = nil
        openingTask = nil
        inspectorAfterOpening = false
        withoutAnimation {
            openTaskID = nil
            inspectedRunID = nil
            showInspector = false
            highlightedTaskID = nil
        }
    }

    // MARK: The inspector and the list

    // The inspector column beside a task list (cards and the toolbar) could send AppKit into an endless
    // constraints loop that crashed the app. In a stress loop of opening and leaving tasks in the simulator
    // that was about 60% of the time while the inspector stayed open after leaving; about once in 40 when the
    // list cross-faded in as the column slid out; and about once in 140 when both changed in one update,
    // because SwiftUI keeps the column up until a running animation ends. So the two are never on screen
    // together: leaving waits for any inspector animation, takes the column away, and brings the list in a
    // turn later; opening brings the inspector in only once the list has gone.

    /// The task whose open animation is still running, so the list is still on screen (`openTask`).
    @ObservationIgnored private var openingTask: String?
    /// The inspector was asked for while `openingTask` was set.
    @ObservationIgnored private var inspectorAfterOpening = false
    /// Inspector animations still running (`moveInspector`).
    @ObservationIgnored private var inspectorMoves = 0
    /// The switch back to the list, waiting for the inspector (`leaveTask`).
    @ObservationIgnored private var pendingLeave: (() -> Void)?
    /// Counts `leaveTask` calls, so a backstop only finishes the leave it was set for.
    @ObservationIgnored private var leaveCount = 0

    private func enterTask(_ id: String) {
        pendingLeave = nil
        // The inspector belongs to the open task; don't carry another task's agent over.
        if let run = inspectedRunID, !run.hasPrefix(id + "/") { inspectedRunID = nil }
        openTaskID = id
        highlightedTaskID = id
    }

    /// Shows the inspector, but not beside the list: during an open it comes in once the list has gone, and
    /// while a leave is pending it doesn't come back.
    private func presentInspector() {
        guard !showInspector, pendingLeave == nil else { return }
        if openingTask != nil {
            inspectorAfterOpening = true
            return
        }
        moveInspector(shown: true, animated: true)
    }

    private func moveInspector(shown: Bool, animated: Bool) {
        inspectorMoves += 1
        var transaction = Transaction(animation: animated ? Theme.spring : nil)
        transaction.disablesAnimations = !animated
        transaction.addAnimationCompletion(criteria: .removed) { [weak self] in
            // A turn later, so SwiftUI has finished with the column (it collapses it when the animation ends).
            DispatchQueue.main.async { self?.inspectorMoveEnded() }
        }
        withTransaction(transaction) { showInspector = shown }
    }

    private func inspectorMoveEnded() {
        inspectorMoves = max(0, inspectorMoves - 1)
        continueLeaving()
    }

    /// Back to a list, with the inspector closed — it belongs to the open task.
    private func leaveTask(_ change: () -> Void = {}) {
        guard let leaving = openTaskID, showInspector || inspectorMoves > 0 else {
            withAnimation(Theme.spring) {
                change()
                openTaskID = nil
                inspectedRunID = nil
                showInspector = false
            }
            return
        }
        withoutAnimation(change)
        pendingLeave = { [weak self] in
            guard let self, openTaskID == leaving else { return }
            withAnimation(Theme.spring) {
                openTaskID = nil
                inspectedRunID = nil
                showInspector = false
            }
        }
        continueLeaving()
        // A backstop in case an inspector completion never comes (each should, exactly once); well past the
        // spring's settling time (about 0.45 s), so a busy main thread can't make it cut an animation short.
        leaveCount += 1
        let count = leaveCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, leaveCount == count, pendingLeave != nil else { return }
            inspectorMoves = 0
            continueLeaving()
        }
    }

    /// The next step of a pending leave: wait for inspector animations, then take the column away, then (a turn
    /// after that) switch to the list.
    private func continueLeaving() {
        guard pendingLeave != nil, inspectorMoves == 0 else { return }
        if showInspector {
            moveInspector(shown: false, animated: false)
            return
        }
        let leave = pendingLeave
        pendingLeave = nil
        leave?()
    }

    /// No animation at all, `.animation` modifiers included.
    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}
