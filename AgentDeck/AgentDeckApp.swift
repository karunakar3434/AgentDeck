import SwiftUI
import AgentDeckCore

@main
struct AgentDeckApp: App {
    var body: some Scene {
        WindowGroup {
            Text("AgentDeck \(AgentDeckCore.version)")
                .frame(minWidth: 420, minHeight: 300)
        }
    }
}
