import SwiftUI
import AgentDeckCore
import AgentDeckState

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
    var score: Int
}

private struct CommandPalette: View {
    var close: () -> Void
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var query = ""
    @State private var selection = 0
    /// Snapshot of searchable items, taken once per opening (a jump palette doesn't need
    /// live re-ranking; `open` re-looks up the task anyway).
    @State private var corpus: [Candidate]?
    @State private var items: [PaletteItem] = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
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
                                    .contentShape(.rect)
                                    .onTapGesture { selection = i; open(items) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, s in
                        if items.indices.contains(s) { proxy.scrollTo(items[s].id) }
                    }
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
        .onChange(of: query, initial: true) { _, q in
            if corpus == nil { corpus = Self.corpus(from: store) }
            items = Self.rank(corpus ?? [], query: q.trimmingCharacters(in: .whitespaces).lowercased())
            selection = 0
        }
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

    /// A searchable entry with its lowercased search keys precomputed.
    struct Candidate {
        var item: PaletteItem
        var keys: [String]
        var boost: Int
        /// Shown with an empty query.
        var featured: Bool
    }

    private static func corpus(from store: DeckStore) -> [Candidate] {
        var out: [Candidate] = []
        for (s, sym) in [(SidebarSection.active, "bolt.horizontal.circle"), (.history, "clock.arrow.circlepath")] {
            out.append(Candidate(item: PaletteItem(id: "section-\(s.title)", kind: .section(s), title: "Go to \(s.title)",
                                                   subtitle: "", symbol: sym, taskID: nil, score: 0),
                                 keys: [s.title.lowercased()], boost: 5, featured: true))
        }
        for t in store.activeTasks + store.inactiveTasks {
            out.append(Candidate(item: PaletteItem(id: t.id, kind: .task, title: t.title, subtitle: "\(t.projectName) · \(t.status.label)",
                                                   symbol: t.status.symbol, taskID: t.id, score: 0),
                                 keys: [t.title.lowercased(), t.projectName.lowercased()],
                                 boost: t.status.isActive ? 20 : 0, featured: true))
            for r in t.runs.dropFirst() {
                out.append(Candidate(item: PaletteItem(id: r.id, kind: .agent, title: "\(r.agentType): \(r.description)",
                                                       subtitle: "\(t.title) · \(r.status.label)",
                                                       symbol: AgentGlyph.symbol(for: r.agentType, isMain: false), taskID: t.id, score: 0),
                                     keys: [r.agentType.lowercased(), r.description.lowercased()],
                                     boost: r.status == .running ? 15 : 0, featured: r.status == .running))
            }
        }
        return out
    }

    private static func rank(_ corpus: [Candidate], query q: String) -> [PaletteItem] {
        var scored: [PaletteItem] = []
        for c in corpus {
            if q.isEmpty {
                guard c.featured else { continue }
                var item = c.item
                item.score = c.boost
                scored.append(item)
            } else {
                let s = c.keys.map { Fuzzy.score(q, $0) }.max() ?? 0
                guard s > 0 else { continue }
                var item = c.item
                item.score = s + c.boost
                scored.append(item)
            }
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(50))
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
        .background(isSelected ? Color.accentColor : .clear, in: .rect(cornerRadius: 8))
    }
}

/// Tiny subsequence matcher: contiguous and word-start matches score higher.
enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let t = text
        if t.hasPrefix(query) { return 100 }  // callers pass lowercased text
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
