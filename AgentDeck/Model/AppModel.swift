import SwiftUI
import AgentDeckCore

/// Owns the store, navigation, notifications and the active agent source.
@MainActor @Observable
final class AppModel {
    let store = DeckStore()
    let nav = Navigator()
    let notifications = Notifier()

    private(set) var isMock = CommandLine.arguments.contains("-mock")
    private(set) var isStress = CommandLine.arguments.contains("-stress")

    /// Opens (or brings forward) the main window; set by a view that has `openWindow`.
    var openMainWindow: (() -> Void)?

    private var started = false
    private var source: (any AgentSource)?
    private var consumer: Task<Void, Never>?

    func start() {
        guard !started else { return }
        started = true
        DebugAutomation.install(app: self)
        ReduceMotion.startObserving()
        notifications.activate()
        notifications.onOpenTask = { [weak self] id in self?.openFromNotification(id) }
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
        nav.openTaskID = nil
        nav.inspectedRunID = nil

        let d = UserDefaults.standard
        let new: any AgentSource
        if isMock {
            new = MockAgentSource(scenario: isStress ? .stress : .demo)
        } else {
            let root = URL(fileURLWithPath: d.string(forKey: SettingsKey.dataFolder) ?? SettingsKey.defaultDataFolder)
            new = ClaudeCodeSource(configuration: .init(
                dataRoot: root,
                historyWindow: TimeInterval(max(1, d.integer(forKey: SettingsKey.historyHours))) * 3600
            ))
        }
        source = new
        let store = self.store
        consumer = Task { [weak self] in
            for await update in await new.updates() {
                if Task.isCancelled { break }
                store.apply(update)
            }
        }
    }

    private var lastBadge: Int = -1

    private func updateDockBadge() {
        let n = UserDefaults.standard.bool(forKey: SettingsKey.dockBadge) && !Experiments.has("nodock") ? store.glanceRunningCount : 0
        guard n != lastBadge else { return }
        lastBadge = n
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func openFromNotification(_ id: String) {
        guard let t = store.tasks[id] else { return }
        nav.section = t.status.isActive ? .active : .history
        nav.openTask(id)
        openMainWindow?()
        NSApp.activate()
    }
}
