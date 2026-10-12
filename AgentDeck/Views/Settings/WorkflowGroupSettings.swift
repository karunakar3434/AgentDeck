import SwiftUI
import AgentDeckCore

/// Settings › Groups: the workflow groups, in order, and their rules. Folder projects and Others aren't
/// configured here; they follow from each task's working folder.
struct WorkflowGroupSettings: View {
    @Environment(AppModel.self) private var app
    @State private var expanded: Set<UUID> = []
    @State private var pendingDelete: WorkflowGroup?
    @State private var confirmRestore = false

    var body: some View {
        let groups = app.workflowRules.groups
        Form {
            Section {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    DisclosureGroup(isExpanded: expandedBinding(group.id)) {
                        GroupEditor(group: binding(group.id), problem: problem(at: index),
                                    canMoveUp: index > 0, canMoveDown: index < groups.count - 1,
                                    move: { move(group.id, by: $0) }, delete: { pendingDelete = group })
                    } label: {
                        GroupLabel(group: group, hasProblem: problem(at: index) != nil)
                    }
                }
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkflowRules.othersName)
                        Text("Sessions with no project folder that match no group. Always last.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: ProjectKind.others.symbol())
                }
                Button("Add Group", systemImage: "plus") { add() }
            } header: {
                Text("Workflow groups")
            } footer: {
                Text("A task goes in the first group with a matching rule, otherwise in its project folder, otherwise in Others. Folder projects are automatic: one per project folder.")
            }
            Section {
                Button("Restore Default Groups…") { confirmRestore = true }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .confirmationDialog("Delete “\(pendingDelete?.displayName ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Group", role: .destructive) {
                if let id = pendingDelete?.id { update { $0.groups.removeAll { $0.id == id } } }
                pendingDelete = nil
            }
        } message: {
            Text("Its tasks go back to their project folders, or to Others.")
        }
        .confirmationDialog("Restore the default groups?", isPresented: $confirmRestore) {
            Button("Restore Defaults", role: .destructive) {
                expanded = []
                app.setWorkflowRules(.defaults)
            }
        } message: {
            Text("GmailMonitor, PubgMontages and TradingBot with their default rules replace your groups.")
        }
    }

    /// Why a group doesn't take part in matching, if it doesn't.
    private func problem(at index: Int) -> String? {
        let groups = app.workflowRules.groups
        let name = groups[index].displayName
        if name.isEmpty { return "Give the group a name; until then it matches nothing." }
        if WorkflowRules.isReserved(name) { return "“\(WorkflowRules.othersName)” is reserved for sessions that match no group." }
        if groups[..<index].contains(where: { $0.displayName == name }) {
            return "A group above has the same name, so this one is ignored."
        }
        if groups[index].hasNoRules { return "Add a rule; a group without rules matches nothing." }
        return nil
    }

    private func binding(_ id: UUID) -> Binding<WorkflowGroup> {
        Binding(
            get: { app.workflowRules.groups.first { $0.id == id } ?? WorkflowGroup(id: id, name: "") },
            set: { group in
                update { rules in
                    if let i = rules.groups.firstIndex(where: { $0.id == id }) { rules.groups[i] = group }
                }
            })
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { open in if open { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func update(_ change: (inout WorkflowRules) -> Void) {
        var rules = app.workflowRules
        change(&rules)
        app.setWorkflowRules(rules)
    }

    private func add() {
        let names = Set(app.workflowRules.groups.map(\.displayName))
        let name = (1...).lazy.map { $0 == 1 ? "New Group" : "New Group \($0)" }.first { !names.contains($0) }!
        let group = WorkflowGroup(name: name)
        update { $0.groups.append(group) }
        expanded.insert(group.id)
    }

    private func move(_ id: UUID, by offset: Int) {
        update { rules in
            guard let i = rules.groups.firstIndex(where: { $0.id == id }) else { return }
            let j = i + offset
            guard rules.groups.indices.contains(j) else { return }
            rules.groups.swapAt(i, j)
        }
    }
}

private struct GroupLabel: View {
    var group: WorkflowGroup
    var hasProblem: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ProjectKind.workflow.symbol())
                .foregroundStyle(.secondary)
            Text(group.displayName.isEmpty ? "Untitled group" : group.displayName)
                .foregroundStyle(group.displayName.isEmpty ? .secondary : .primary)
            if hasProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This group isn't used for matching")
            }
            Spacer()
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let n = [group.agentTypes, group.skills, group.tools, group.folders, group.titleKeywords]
            .reduce(0) { $0 + $1.count }
        return n == 1 ? "1 rule" : "\(n) rules"
    }
}

private struct GroupEditor: View {
    @Binding var group: WorkflowGroup
    var problem: String?
    var canMoveUp: Bool
    var canMoveDown: Bool
    var move: (Int) -> Void
    var delete: () -> Void

    var body: some View {
        TextField("Name", text: $group.name)
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        RuleField(title: "Agent types", values: $group.agentTypes, example: "gmail-monitor")
        RuleField(title: "Skills", values: $group.skills, example: "anthropic-skills:morning")
        RuleField(title: "Tools", values: $group.tools, example: "createScheduledPost")
        RuleField(title: "Folders", values: $group.folders, example: "~/Projects/Pubg_Tools, trading-bot*")
        RuleField(title: "Title keywords", values: $group.titleKeywords, example: "PUBG, montage")
        Text("""
            Separate values with commas. Any one matching value is enough. A folder starting with / or ~ matches \
            it and everything inside; a bare name (with * and ?) matches the working folder or any parent. Title \
            keywords match at the start of a word, only for sessions with no project folder.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Button("Move Up", systemImage: "arrow.up") { move(-1) }
                .disabled(!canMoveUp)
            Button("Move Down", systemImage: "arrow.down") { move(1) }
                .disabled(!canMoveDown)
            Spacer()
            Button("Delete Group…", role: .destructive, action: delete)
        }
    }
}

/// A comma-separated list. The text is the source while editing, so typing "a, " isn't rewritten to "a".
private struct RuleField: View {
    var title: String
    @Binding var values: [String]
    var example: String
    @State private var text: String

    init(title: String, values: Binding<[String]>, example: String) {
        self.title = title
        _values = values
        self.example = example
        _text = State(initialValue: values.wrappedValue.joined(separator: ", "))
    }

    var body: some View {
        TextField(title, text: $text, prompt: Text("e.g. \(example)"), axis: .vertical)
            .lineLimit(1...3)
            .onChange(of: text) { _, new in
                let parsed = Self.parse(new)
                if parsed != values { values = parsed }
            }
            .onChange(of: values) { _, new in
                // Changed from outside (Restore Defaults): show the new values instead of writing stale text back.
                if Self.parse(text) != new { text = new.joined(separator: ", ") }
            }
    }

    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
