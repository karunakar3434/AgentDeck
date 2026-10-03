import Foundation
import Testing
@testable import AgentDeckCore

@Suite struct LineScannerTests {
    private func kind(_ json: String) -> LineKind {
        Data(json.utf8).withUnsafeBytes { LineScanner.classify($0) }
    }

    @Test func typeFirstMetadataLines() {
        #expect(kind(#"{"type":"queue-operation","operation":"enqueue","content":"x"}"#) == .queueOperation)
        #expect(kind(#"{"type":"custom-title","customTitle":"T","sessionId":"s"}"#) == .customTitle)
        #expect(kind(#"{"type":"ai-title","aiTitle":"T"}"#) == .aiTitle)
        #expect(kind(#"{"type":"relocated","relocatedCwd":"/x"}"#) == .relocated)
        #expect(kind(#"{"type":"cost-state","totalCostUSD":1.2}"#) == .costState)
        #expect(kind(#"{"type":"fork-context-ref","agentId":"a"}"#) == .forkContextRef)
    }

    @Test func skippedTypesAreNeverDecoded() {
        for type in ["file-history-snapshot", "file-history-delta", "mode", "permission-mode", "atis-latch",
                     "last-prompt", "agent-name", "bridge-session", "summary", "progress", "something-new"] {
            #expect(kind(#"{"type":"\#(type)","x":{"type":"user"}}"#) == .skip, "\(type)")
        }
    }

    @Test func typeAfterShortEnvelopeKeys() {
        let user = #"{"parentUuid":null,"isSidechain":false,"promptId":"5b72","type":"user","message":{"role":"user","content":"hi"}}"#
        #expect(kind(user) == .user)
        let sub = #"{"parentUuid":"p","isSidechain":true,"promptId":"x","agentId":"a1","type":"user","message":{}}"#
        #expect(kind(sub) == .user)
        #expect(kind(#"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"turn_duration"}"#) == .system)
    }

    @Test func messageBeforeTypeMeansAssistant() {
        let line = #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","type":"message","content":[{"type":"text","text":"{\"type\":\"user\"}"}]},"requestId":"r","type":"assistant"}"#
        #expect(kind(line) == .assistant)
    }

    @Test func attachmentBeforeTypeReadsTheAttachmentType() {
        let queued = #"{"parentUuid":"p","isSidechain":false,"attachment":{"type":"queued_command","prompt":"<task-notification>"},"type":"attachment"}"#
        #expect(kind(queued) == .queuedCommand)
        let reminder = #"{"parentUuid":"p","isSidechain":false,"attachment":{"type":"total_tokens_reminder","n":1},"type":"attachment"}"#
        #expect(kind(reminder) == .skip)
        // Attachment type not first inside the attachment object: undecided, full decode.
        #expect(kind(#"{"attachment":{"prompt":"x","type":"queued_command"},"type":"attachment"}"#) == .decode)
        // `type` before `attachment` keeps looking for the attachment object.
        #expect(kind(#"{"type":"attachment","attachment":{"type":"queued_command"}}"#) == .queuedCommand)
    }

    @Test func whitespaceAndEscapes() {
        #expect(kind("  {\n \"parentUuid\" : \"a\\\"b\" ,\t\"type\" :  \"user\" }") == .user)
        #expect(kind(#"{ "isSidechain" : true , "nested" : { "type" : "assistant" , "a" : [1, {"type":"x"}] }, "type": "system" }"#) == .system)
    }

    @Test func undecidedWithinLimitFallsBackToDecode() {
        let big = String(repeating: "x", count: 5000)
        #expect(kind(#"{"parentUuid":"\#(big)","type":"user"}"#) == .decode)
        #expect(kind("not json") == .decode)
        #expect(kind("{}") == .decode)
    }

    /// Every line of every fixture classifies the same as a reference decode of its `type` (and attachment type).
    @Test func agreesWithReferenceDecodeOnAllFixtureLines() throws {
        let projects = Fixtures.root.appendingPathComponent("projects")
        let paths = FileManager.default.enumerator(atPath: projects.path)!
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".jsonl") }
        #expect(paths.count == 16)
        var checked = 0
        for rel in paths {
            for line in Fixtures.lines(projects.appendingPathComponent(rel).path) {
                let obj = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
                let type = obj["type"] as? String
                let expected: LineKind
                switch type {
                case "user": expected = .user
                case "assistant": expected = .assistant
                case "system": expected = .system
                case "queue-operation": expected = .queueOperation
                case "custom-title": expected = .customTitle
                case "ai-title": expected = .aiTitle
                case "relocated": expected = .relocated
                case "cost-state": expected = .costState
                case "fork-context-ref": expected = .forkContextRef
                case "attachment":
                    expected = (obj["attachment"] as? [String: Any])?["type"] as? String == "queued_command" ? .queuedCommand : .skip
                default: expected = .skip
                }
                let got = line.withUnsafeBytes { LineScanner.classify($0) }
                #expect(got == expected, "\(rel): \(type ?? "nil")")
                checked += 1
            }
        }
        #expect(checked > 6_000)
    }
}
