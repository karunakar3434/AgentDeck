import Foundation
import ServiceManagement

/// Launch at login. Uses `SMAppService.mainApp`; if the system refuses to register this
/// locally signed (ad-hoc, no Team ID) build, falls back to a per-user LaunchAgent that
/// opens the app at login. The agent file exists only while the user has the toggle on.
enum LoginItem {
    private static let label = "com.karun.AgentDeck.login"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            do {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .enabled { return }
            } catch {
                // Fall through to the LaunchAgent below.
            }
            try writeAgent()
        } else {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try? SMAppService.mainApp.unregister()
            }
            if FileManager.default.fileExists(atPath: agentURL.path) {
                try FileManager.default.removeItem(at: agentURL)
            }
        }
    }

    private static func writeAgent() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
    }
}
