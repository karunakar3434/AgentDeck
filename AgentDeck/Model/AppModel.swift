import SwiftUI
import AgentDeckCore
import AgentDeckState

/// Owns the store, navigation, notifications and the active agent source.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let store = DeckStore()
    let nav = Navigator()
    let notifications = Notifier()

    private(set) var isMock = CommandLine.arguments.contains("-mock")
    private(set) var isStress = CommandLine.arguments.contains("-stress")

    /// Opens (or brings forward) the main window; set by a view that has `openWindow`.
    var openMainWindow: (() -> Void)?
    /// Opens the Settings window; set by a view that has `openSettings`.
    var openSettingsWindow: (() -> Void)?
    var settingsTab: SettingsTab = .general

    /// Workflow groups (Settings › Groups), saved in UserDefaults. Edits reach the sidebar and the source
    /// after a short pause, so typing a rule doesn't reclassify every task on each keystroke.
    private(set) var workflowRules = WorkflowRulesStorage.load()
    /// The rules the store and source last received.
    @ObservationIgnored private var appliedRules: WorkflowRules?
    @ObservationIgnored private var rulesTask: Task<Void, Never>?

    private var started = false
    private var source: (any AgentSource)?
    private var consumer: Task<Void, Never>?

    private var prepared = false

    /// Runs before launch completes (app delegate), so a notification that launched the
    /// app finds its delegate in place.
    func prepareForLaunch() {
        guard !prepared else { return }
        prepared = true
        notifications.onOpenTask = { [weak self] id in self?.openFromNotification(id) }
        notifications.activate()
    }

    func start() {
        guard !started else { return }
        started = true
        prepareForLaunch()
        DebugAutomation.install(app: self)
        ReduceMotion.startObserving()
        store.onGlanceChange = { [weak self] _ in self?.updateDockBadge() }
        store.onEvent = { [weak self] event in
            guard let self else { return }
            notifications.handle(event, store: store)
        }
        connect()
    }

    func setMock(_ on: Bool, stress: Bool = false) {
        guard on != isMock || stress != isStress else { return }
        isMock = on
        isStress = on && stress
        restartSource()
    }

    func restartSource() {
        guard started else { return }
        connect()
    }

    private func connect() {
        consumer?.cancel()
        let old = source
        Task { await old?.stop() }
        store.reset()
        nav.reset()

        let d = UserDefaults.standard
        let rules = workflowRules
        rulesTask?.cancel()
        appliedRules = rules
        store.setWorkflowGroups(rules.groupNames)
        followRenamedGroups(to: rules)
        let new: any AgentSource
        if isMock {
            new = MockAgentSource(scenario: isStress ? .stress : .demo, rules: rules)
        } else {
            let root = URL(fileURLWithPath: d.string(forKey: SettingsKey.dataFolder) ?? SettingsKey.defaultDataFolder)
            var configuration = ClaudeCodeSource.Configuration(
                dataRoot: root,
                historyWindow: TimeInterval(max(1, d.integer(forKey: SettingsKey.historyHours))) * 3600
            )
            configuration.workflowRules = rules
            new = ClaudeCodeSource(configuration: configuration)
        }
        source = new
        let store = self.store
        consumer = Task { [weak self] in
            for await update in await new.updates() {
                if Task.isCancelled { break }
                store.apply(update)
                self?.closeVanishedTask()
                self?.resolvePendingOpen()
            }
        }
    }

    // MARK: Workflow groups

    func setWorkflowRules(_ rules: WorkflowRules) {
        guard rules != workflowRules else { return }
        workflowRules = rules
        WorkflowRulesStorage.save(rules)
        rulesTask?.cancel()
        rulesTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.applyWorkflowRules()
        }
    }

    /// Hands the current rules to the store (sidebar entries) and the source (which reclassifies every task).
    private func applyWorkflowRules() async {
        let rules = workflowRules
        guard rules != appliedRules else { return }
        appliedRules = rules
        store.setWorkflowGroups(rules.groupNames)
        followRenamedGroups(to: rules)
        await source?.setWorkflowRules(rules)
    }

    /// Each active group's last name, by id. Kept while a group is briefly inactive (its name cleared or
    /// clashing mid-edit), so a rename through an empty name is still followed.
    @ObservationIgnored private var activeGroupNames: [UUID: String] = [:]

    /// Keeps the selected sidebar entry and the project filter on a group that was renamed, and lets go of
    /// a deleted group's entry. Call after the store has the new group names.
    private func followRenamedGroups(to rules: WorkflowRules) {
        let now = Dictionary(rules.activeGroups.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let names = Set(rules.groupNames)
        let ids = Set(rules.groups.map(\.id))
        for (id, before) in activeGroupNames where !names.contains(before) {
            if let after = now[id] {
                // Renamed (the old name is no entry any more, so it's this group's).
                if nav.section == .project(before) { nav.section = .project(after) }
                if nav.filters.projects.remove(before) != nil { nav.filters.projects.insert(after) }
            } else if !ids.contains(id), !store.projects.contains(before) {
                // Deleted, and no folder project has the name.
                if nav.section == .project(before) { nav.show(.active) }
                nav.filters.projects.remove(before)
            }
        }
        activeGroupNames = activeGroupNames.filter { ids.contains($0.key) }.merging(now) { _, new in new }
    }

    private var lastBadge: Int = -1

    func updateDockBadge() {
        let n = UserDefaults.standard.bool(forKey: SettingsKey.dockBadge) && !Experiments.has("nodock") ? store.glanceRunningCount : 0
        guard n != lastBadge else { return }
        lastBadge = n
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    /// A task to open once it has loaded (a notification clicked at launch or mid-restart).
    private var pendingOpenTaskID: String?

    func openFromNotification(_ id: String) {
        openMainWindow?()
        NSApp.activate()
        guard let t = store.tasks[id] else { pendingOpenTaskID = id; return }
        pendingOpenTaskID = nil
        nav.section = t.status.isActive ? .active : .history
        nav.openTask(id)
    }

    /// The open task left the store (it aged out of the history window, or the simulator pruned it). The detail
    /// already falls back to the list, so leave the task properly — otherwise its inspector, Back button and
    /// title stay up beside that list.
    private func closeVanishedTask() {
        if let id = nav.openTaskID, store.tasks[id] == nil { nav.closeTask() }
    }

    private func resolvePendingOpen() {
        guard let id = pendingOpenTaskID else { return }
        if store.tasks[id] != nil { openFromNotification(id) }
        else if store.initialLoadComplete { pendingOpenTaskID = nil }  // gone from the window
    }
}
