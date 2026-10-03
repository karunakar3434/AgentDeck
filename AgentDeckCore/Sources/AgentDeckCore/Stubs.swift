import Foundation

// TEMPORARY placeholders so the app target compiles while the core is built.
// Replace with the real implementations (and delete this file).

public final class ClaudeCodeSource: AgentSource {
    public struct Configuration: Sendable {
        public var dataRoot: URL
        public var historyWindow: TimeInterval
        public init(dataRoot: URL, historyWindow: TimeInterval) {
            self.dataRoot = dataRoot
            self.historyWindow = historyWindow
        }
    }
    public let configuration: Configuration
    public init(configuration: Configuration) { self.configuration = configuration }
    public func updates() async -> AsyncStream<DeckUpdate> {
        AsyncStream { $0.yield(DeckUpdate(initialLoadComplete: true)) }
    }
    public func stop() async {}
}

public final class MockAgentSource: AgentSource {
    public enum Scenario: Sendable { case demo, stress }
    public let scenario: Scenario
    public init(scenario: Scenario) { self.scenario = scenario }
    public func updates() async -> AsyncStream<DeckUpdate> {
        AsyncStream { $0.yield(DeckUpdate(initialLoadComplete: true)) }
    }
    public func stop() async {}
}
