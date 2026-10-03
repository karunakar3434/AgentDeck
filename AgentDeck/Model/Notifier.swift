import Foundation
import UserNotifications
import AgentDeckCore
import AgentDeckState

/// Opt-in native notifications. Clicking one opens the task.
@MainActor @Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorizationNote: String?
    /// Called with a task id when the user clicks a notification.
    var onOpenTask: ((String) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func activate() {
        center.delegate = self
        refreshNote()
    }

    func requestAuthorization() {
        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                authorizationNote = "Notifications are unavailable: \(error.localizedDescription)"
            }
            refreshNote()
        }
    }

    private func refreshNote() {
        Task {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .denied:
                authorizationNote = "Notifications are turned off for AgentDeck in System Settings › Notifications."
            default:
                if authorizationNote?.hasPrefix("Notifications are turned off") == true { authorizationNote = nil }
            }
        }
    }

    func handle(_ event: DeckEvent, store: DeckStore) {
        let d = UserDefaults.standard
        // Simulated agents never post real notifications.
        if case .taskFinished(let id, _) = event, store.tasks[id]?.source == "mock" { return }
        if case .subagentFailed(let id, _) = event, store.tasks[id]?.source == "mock" { return }
        switch event {
        case .taskFinished(let id, let failed):
            guard d.bool(forKey: SettingsKey.notifyTaskFinished), let t = store.tasks[id] else { return }
            post(id: "task-\(id)-\(t.lastActivityAt.timeIntervalSince1970)",
                 title: failed ? "Task failed" : "Task finished",
                 body: "\(t.title) — \(t.projectName)", taskID: id)
        case .subagentFailed(let taskID, let runID):
            guard d.bool(forKey: SettingsKey.notifySubagentFailed), let r = store.runs[runID] else { return }
            post(id: "run-\(runID)", title: "\(r.agentType) failed",
                 body: r.description, taskID: taskID)
        }
    }

    private func post(id: String, title: String, body: String, taskID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["taskID": taskID]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["taskID"] as? String else { return }
        await MainActor.run { onOpenTask?(id) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
