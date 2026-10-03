import Foundation

/// One `<task-notification>` block (data-sources §3): how a background agent's finish reaches the parent.
///
/// The same notice can arrive up to three times (queue-operation enqueue, queued_command attachment, user
/// line). `identity` makes applying it idempotent.
struct TaskNotice: Sendable, Hashable {
    var taskID: String?
    var toolUseID: String?
    /// `completed` | `failed` (others are kept verbatim).
    var status: String?
    var summary: String?
    /// `<result>`: whitespace collapsed, ≤ 400 chars, delivery stubs dropped.
    var result: String?
    var durationMs: Int?
    var subagentTokens: Int?

    var identity: String { "\(taskID ?? "")|\(toolUseID ?? "")|\(status ?? "")|\(durationMs ?? -1)" }

    static let openTag = "<task-notification>"
    static let closeTag = "</task-notification>"

    /// The notices of a text that *is* a notification: it starts with `<task-notification>` (after
    /// whitespace). A message that merely quotes one (a peer handback, a prompt) yields nothing.
    static func parseLeading(_ text: String) -> [TaskNotice] {
        guard text.drop(while: { $0.isWhitespace || $0.isNewline }).hasPrefix(openTag) else { return [] }
        return parseAll(text)
    }

    /// Every notification block in `text`.
    static func parseAll(_ text: String) -> [TaskNotice] {
        guard text.contains(openTag) else { return [] }
        var notices: [TaskNotice] = []
        var rest = text[...]
        while let open = rest.range(of: openTag) {
            let bodyStart = open.upperBound
            let close = rest.range(of: closeTag, range: bodyStart..<rest.endIndex)
            let body = rest[bodyStart..<(close?.lowerBound ?? rest.endIndex)]
            if let notice = parse(body: body) { notices.append(notice) }
            guard let close else { break }
            rest = rest[close.upperBound...]
        }
        return notices
    }

    static func parse(body: Substring) -> TaskNotice? {
        var n = TaskNotice()
        n.taskID = tag("task-id", in: body).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        n.toolUseID = tag("tool-use-id", in: body).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        n.status = tag("status", in: body).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        n.summary = tag("summary", in: body).map { TextUtil.firstLine(String($0), limit: 200) }
        n.result = tag("result", in: body).flatMap { TextUtil.report(String($0)) }
        n.durationMs = tag("duration_ms", in: body).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        n.subagentTokens = tag("subagent_tokens", in: body).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard n.taskID != nil || n.toolUseID != nil else { return nil }
        return n
    }

    private static func tag(_ name: String, in body: Substring) -> Substring? {
        guard let open = body.range(of: "<\(name)>") else { return nil }
        guard let close = body.range(of: "</\(name)>", range: open.upperBound..<body.endIndex) else { return nil }
        return body[open.upperBound..<close.lowerBound]
    }
}
