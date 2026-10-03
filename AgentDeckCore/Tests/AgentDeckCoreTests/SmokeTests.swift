import Testing
@testable import AgentDeckCore

@Test func versionIsSet() {
    #expect(!AgentDeckCore.version.isEmpty)
}
