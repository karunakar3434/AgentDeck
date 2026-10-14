import SwiftUI
import AgentDeckCore

/// Installs the notification delegate before launch completes, so a click on a
/// notification that launched the app is delivered (and remembered until the task loads).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppModel.shared.prepareForLaunch()
    }
}

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared
    @AppStorage(SettingsKey.showMenuBarItem) private var showMenuBarItem = true

    init() {
        SettingsKey.registerDefaults()
    }

    var body: some Scene {
        Window("AgentDeck", id: "main") {
            MainWindow()
                .environment(app)
                .environment(app.store)
                .environment(app.nav)
                .task { app.start() }
                .onAppear { DispatchQueue.main.async { LaunchMetrics.windowAppeared() } }
        }
        .defaultSize(width: 980, height: 680)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(app: app) }

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarPopover()
                .environment(app)
                .environment(app.store)
                .environment(app.nav)
        } label: {
            MenuBarLabel()
                .environment(app)
                .environment(app.store)
                .task { app.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

struct AppCommands: Commands {
    var app: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Active") { app.nav.show(.active) }
                .keyboardShortcut("1", modifiers: .command)
            Button("History") { app.nav.show(.history) }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("Go to Task or Agent…") { withAnimation(Theme.spring) { app.nav.showPalette.toggle() } }
                .keyboardShortcut("k", modifiers: .command)
            Button("Search") { app.nav.isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            // Guarded in toggleInspector, not .disabled: a menu command's disabled state didn't follow the open task, so ⌥⌘I stayed off.
            Button(app.nav.showInspector ? "Hide Inspector" : "Show Inspector") { app.nav.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu("Debug") {
            Toggle("Simulate Agents", isOn: Binding(get: { app.isMock }, set: { app.setMock($0) }))
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Stress Test (20 tasks × 15 agents)") { app.setMock(true, stress: true) }
                .disabled(app.isMock && app.isStress)
        }
    }
}
