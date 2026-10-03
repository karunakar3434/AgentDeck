import SwiftUI
import AgentDeckCore

/// ⌘K palette: jump to any task or agent.
struct CommandPaletteHost: View {
    @Environment(Navigator.self) private var nav

    var body: some View {
        ZStack(alignment: .top) {
            if nav.showPalette {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                CommandPalette(close: close)
                    .padding(.top, 60)
                    .padding(.horizontal, 16)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: nav.showPalette)
    }

    private func close() { nav.showPalette = false }
}

private struct PaletteItem: Identifiable, Hashable {
    enum Kind: Hashable { case task, agent, section(SidebarSection) }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    let taskID: String?
    let score: Int
}

private struct CommandPalette: View {
    var close: () -> Void
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let items = results()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to a task or agent…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { open(items) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, items.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                Text("esc")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary))
            }
            .padding(14)

            if !items.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                PaletteRow(item: item, isSelected: i == selection)
                                    .id(i)
                                    .contentShape(.rect)
                                    .onTapGesture { selection = i; open(items) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, s in proxy.scrollTo(s) }
                }
            } else if !query.isEmpty {
                Divider()
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .frame(maxWidth: 560)
        // A thick material rather than clear glass: results must stay legible over busy cards.
        .background(.thickMaterial, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 28, y: 12)
        .onAppear { fieldFocused = true; selection = 0 }
        .onChange(of: query) { selection = 0 }
    }

    private func open(_ items: [PaletteItem]) {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        close()
        switch item.kind {
        case .task:
            if let t = item.taskID, let task = store.tasks[t] {
                nav.section = task.status.isActive ? .active : .history
                nav.openTask(t)
            }
        case .agent:
            if let t = item.taskID, let task = store.tasks[t] {
                nav.section = task.status.isActive ? .active : .history
                nav.inspect(item.id, in: t)
            }
        case .section(let s):
            nav.show(s)
        }
    }

    private func results() -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [PaletteItem] = []
        let sections: [(SidebarSection, String)] = [(.active, "bolt.horizontal.circle"), (.history, "clock.arrow.circlepath")]
        for (s, sym) in sections {
            let score = Fuzzy.score(q, s.title)
            if q.isEmpty || score > 0 {
                out.append(PaletteItem(id: "section-\(s.title)", kind: .section(s), title: "Go to \(s.title)",
                                       subtitle: "", symbol: sym, taskID: nil, score: score + (q.isEmpty ? 0 : 5)))
            }
        }
        for id in store.activeTaskIDs + store.inactiveTaskIDs {
            guard let t = store.tasks[id] else { continue }
            let score = max(Fuzzy.score(q, t.title), Fuzzy.score(q, t.projectName))
            if q.isEmpty || score > 0 {
                out.append(PaletteItem(id: t.id, kind: .task, title: t.title, subtitle: "\(t.projectName) · \(t.status.label)",
                                       symbol: t.status.symbol, taskID: t.id,
                                       score: score + (t.status.isActive ? 20 : 0)))
            }
            for rid in t.runIDs.dropFirst() {
                guard let r = store.runs[rid] else { continue }
                let s = max(Fuzzy.score(q, r.agentType), Fuzzy.score(q, r.description))
                if (q.isEmpty && r.status == .running) || (!q.isEmpty && s > 0) {
                    out.append(PaletteItem(id: r.id, kind: .agent, title: "\(r.agentType): \(r.description)",
                                           subtitle: "\(t.title) · \(r.status.label)",
                                           symbol: AgentGlyph.symbol(for: r.agentType, isMain: false), taskID: t.id,
                                           score: s + (r.status == .running ? 15 : 0)))
                }
            }
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(50))
    }
}

private struct PaletteRow: View {
    var item: PaletteItem
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "return").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? .white : .primary)
        .drawingGroup()
        .background(isSelected ? Color.accentColor : .clear, in: .rect(cornerRadius: 8))
    }
}

/// Tiny subsequence matcher: contiguous and word-start matches score higher.
enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let t = text.lowercased()
        if t.hasPrefix(query) { return 100 }
        if t.contains(query) { return 60 }
        var score = 0, ti = t.startIndex
        for qc in query {
            guard let found = t[ti...].firstIndex(of: qc) else { return 0 }
            score += (found == ti) ? 3 : 1
            ti = t.index(after: found)
        }
        return score
    }
}
