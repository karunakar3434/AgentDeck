import SwiftUI
import AgentDeckCore
import AgentDeckState

/// Live counts across the top of the Active view.
struct HeaderStrip: View {
    @Environment(DeckStore.self) private var store
    var activeCount: Int
    @State private var columns = 4

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            activeTile
            agentsTile
            modelsTile
            LongestTile()
        }
        .onGeometryChange(for: Int.self) { $0.size.width >= 4 * 170 + 30 ? 4 : 2 } action: { columns = $0 }
    }

    private var activeTile: some View {
        StatTile(title: "Active tasks", symbol: "bolt.horizontal.fill", tint: .blue) {
            Text("\(activeCount)")
                .contentTransition(.numericText(value: Double(activeCount)))
                .animation(Theme.spring, value: activeCount)
        }
    }

    private var agentsTile: some View {
        // The throttled count: rolls at most twice a second instead of animating constantly.
        let n = store.glanceRunningCount
        return StatTile(title: "Running agents", symbol: "person.2.fill", tint: .green) {
            Text("\(n)")
                .contentTransition(.numericText(value: Double(n)))
                .animation(Theme.spring, value: n)
        }
    }

    private var modelsTile: some View {
        StatTile(title: "Models in use", symbol: "cpu", tint: .purple) {
            if store.modelsInUse.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 4) {
                    ForEach(store.modelsInUse, id: \.self) { fam in
                        Text(fam.displayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(fam.color)
                            .background(fam.color.opacity(0.14), in: .capsule)
                    }
                }
            }
        }
    }
}

/// The longest-running agent; the only tile that reads the clock.
private struct LongestTile: View {
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        // Longest-running subagent (main agents are almost always older), kept by the store.
        let run = store.longestRun
        StatTile(title: "Longest running", symbol: "hourglass", tint: .orange) {
            if let run {
                HStack(spacing: 6) {
                    ElapsedText(run: run)
                    Text(run.isMain ? (store.tasks[run.taskID]?.title ?? "Main agent") : run.agentType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { if let run { nav.inspect(run.id, in: run.taskID) } }
    }
}

struct StatTile<Value: View>: View {
    var title: String
    var symbol: String
    var tint: Color
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabelStyle(tint: tint))
                .lineLimit(1)
            value
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .frame(height: 28, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .drawingGroup()
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

struct TintedIconLabelStyle: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
