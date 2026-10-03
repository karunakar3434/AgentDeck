import Foundation

/// A producer of live task/agent state. Implementations: `ClaudeCodeSource`
/// (reads Claude Code transcripts) and `MockAgentSource` (simulated agents).
///
/// Other agent tools can be supported later by adding another conforming type.
public protocol AgentSource: AnyObject, Sendable {
    /// Starts the source on first call and returns its stream of coalesced updates.
    /// One stream per source instance.
    func updates() async -> AsyncStream<DeckUpdate>
    /// Stops watching and finishes the stream.
    func stop() async
}
