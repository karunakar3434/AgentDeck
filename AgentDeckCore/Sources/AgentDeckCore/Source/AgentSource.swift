import Foundation

/// A producer of live task/agent state. Implementations: `ClaudeCodeSource`
/// (reads Claude Code transcripts) and `MockAgentSource` (simulated agents).
///
/// Other agent tools can be supported later by adding another conforming type.
public protocol AgentSource: AnyObject, Sendable {
    /// Starts the source on first call and returns its stream of coalesced updates.
    /// One stream per source instance (single consumer); later calls return the same stream.
    func updates() async -> AsyncStream<DeckUpdate>
    /// Idempotent: stops watching and timers, flushes pending writes, and finishes the stream.
    func stop() async
    /// Reclassifies every task, history included, under new workflow rules; changed tasks arrive in the
    /// next update. Nothing is re-read from disk.
    func setWorkflowRules(_ rules: WorkflowRules) async
}

/// Whether a source can do its job, reported through `DeckUpdate.health`.
public enum SourceHealth: Sendable, Hashable {
    case ok
    /// Running with reduced function, for example "Data folder not found".
    case degraded(String)

    /// The message to show, or nil when healthy.
    public var message: String? {
        if case .degraded(let message) = self { return message }
        return nil
    }
}
