import SwiftUI
import ServiceManagement
import AgentDeckCore

enum SettingsKey {
    static let notifyTaskFinished = "notifyTaskFinished"
    static let notifySubagentFailed = "notifySubagentFailed"
    static let menuBarCount = "menuBarCount"
    static let showMenuBarItem = "showMenuBarItem"
    static let dockBadge = "dockBadge"
    static let historyHours = "historyHours"
    static let dataFolder = "dataFolder"

    static let defaultDataFolder = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            notifyTaskFinished: false,
            notifySubagentFailed: false,
            menuBarCount: true,
            showMenuBarItem: true,
            dockBadge: true,
            historyHours: 24,
            dataFolder: defaultDataFolder,
        ])
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Notifications", systemImage: "bell.badge") { NotificationSettings() }
            Tab("Data", systemImage: "externaldrive") { DataSettings() }
        }
        .frame(width: 480)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.showMenuBarItem) private var showMenuBarItem = true
    @AppStorage(SettingsKey.menuBarCount) private var menuBarCount = true
    @AppStorage(SettingsKey.dockBadge) private var dockBadge = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Menu bar and Dock") {
                Toggle("Show menu bar item", isOn: $showMenuBarItem)
                Toggle("Show running-agent count in the menu bar", isOn: $menuBarCount)
                    .disabled(!showMenuBarItem)
                Toggle("Show running-agent count on the Dock icon", isOn: $dockBadge)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't update the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct NotificationSettings: View {
    @AppStorage(SettingsKey.notifyTaskFinished) private var taskFinished = false
    @AppStorage(SettingsKey.notifySubagentFailed) private var subagentFailed = false
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                Toggle("When a task finishes", isOn: $taskFinished)
                Toggle("When a subagent fails", isOn: $subagentFailed)
            } footer: {
                Text("Notifications are off until you turn one on. Clicking a notification opens that task.")
            }
            if let status = app.notifications.authorizationNote {
                Section { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: taskFinished) { _, on in if on { app.notifications.requestAuthorization() } }
        .onChange(of: subagentFailed) { _, on in if on { app.notifications.requestAuthorization() } }
    }
}

private struct DataSettings: View {
    @AppStorage(SettingsKey.historyHours) private var historyHours = 24
    @AppStorage(SettingsKey.dataFolder) private var dataFolder = SettingsKey.defaultDataFolder
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("History") {
                Picker("Keep finished tasks for", selection: $historyHours) {
                    Text("6 hours").tag(6)
                    Text("24 hours").tag(24)
                    Text("3 days").tag(72)
                    Text("7 days").tag(168)
                    Text("30 days").tag(720)
                }
            }
            Section {
                LabeledContent("Claude Code folder") {
                    HStack {
                        Text((dataFolder as NSString).abbreviatingWithTildeInPath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choose() }
                        if dataFolder != SettingsKey.defaultDataFolder {
                            Button("Reset") { dataFolder = SettingsKey.defaultDataFolder }
                        }
                    }
                }
            } footer: {
                Text("AgentDeck reads transcripts from projects/ and live session state from sessions/ in this folder. It never writes there.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: historyHours) { app.restartSource() }
        .onChange(of: dataFolder) { app.restartSource() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: dataFolder)
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { dataFolder = url.path }
    }
}
