import Foundation
import Testing
@testable import AgentDeckCore

@Suite struct TaskNotificationTests {
    @Test func completedWithUsage() throws {
        let text = """
        <task-notification>
        <task-id>a28854a40750f97c0</task-id>
        <tool-use-id>toolu_01Mb7XVJoDJxz1EBAL8YWEmo</tool-use-id>
        <output-file>/private/tmp/x.output</output-file>
        <status>completed</status>
        <summary>Agent "Build site" finished</summary>
        <result>All pages built.
        Second line.</result>
        <usage><subagent_tokens>442287</subagent_tokens><tool_uses>37</tool_uses><duration_ms>368549</duration_ms></usage>
        </task-notification>
        """
        let n = try #require(TaskNotice.parseAll(text).first)
        #expect(n.taskID == "a28854a40750f97c0")
        #expect(n.toolUseID == "toolu_01Mb7XVJoDJxz1EBAL8YWEmo")
        #expect(n.status == "completed")
        #expect(n.summary == "Agent \"Build site\" finished")
        #expect(n.result == "All pages built. Second line.")
        #expect(n.durationMs == 368_549)
        #expect(n.subagentTokens == 442_287)
    }

    @Test func failedWithoutUsage() throws {
        let text = "<task-notification>\n<task-id>a100</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<status>failed</status>\n<summary>Agent \"x\" failed: Agent terminated early due to an API error</summary>\n<result>…</result>\n</task-notification>"
        let n = try #require(TaskNotice.parseAll(text).first)
        #expect(n.status == "failed")
        #expect(n.durationMs == nil)
        #expect(n.subagentTokens == nil)
        #expect(n.summary?.hasSuffix("API error") == true)
    }

    @Test func forkNoticeWithoutToolUseID() throws {
        let text = "<task-notification>\n<task-id>achange-the-wake-up-7f18043573d76831</task-id>\n<status>completed</status>\n<usage><duration_ms>23718</duration_ms></usage>\n</task-notification>"
        let n = try #require(TaskNotice.parseAll(text).first)
        #expect(n.toolUseID == nil)
        #expect(n.taskID == "achange-the-wake-up-7f18043573d76831")
        #expect(n.durationMs == 23_718)
    }

    @Test func identityIsStableAcrossDeliveries() throws {
        let lines = Fixtures.lines(Fixtures.mainPath(Fixtures.f275))
        let parser = LineParser()
        var identities: [String] = []
        for i in [191, 205] {
            switch parser.parse(lines[i]) {
            case .notices(let n, _): identities += n.map(\.identity)
            case .user(let u): identities += u.notices.map(\.identity)
            default: Issue.record("line \(i) has no notice")
            }
        }
        #expect(identities.count == 2)
        #expect(Set(identities).count == 1)
    }

    @Test func multipleAndMalformedBlocks() {
        let text = "<task-notification><task-id>a1</task-id><status>completed</status></task-notification> and " +
            "<task-notification><task-id>a2</task-id><status>failed</status></task-notification>" +
            "<task-notification><status>completed</status></task-notification>"
        let notices = TaskNotice.parseAll(text)
        #expect(notices.map(\.taskID) == ["a1", "a2"])
        #expect(TaskNotice.parseAll("no tags here").isEmpty)
    }
}
