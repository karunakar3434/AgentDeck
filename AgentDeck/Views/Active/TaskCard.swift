import SwiftUI
import AgentDeckCore

/// One card per active task: title, project, elapsed, agent avatars, ETA.
struct TaskCard: View {
    var task: TaskModel
    var namespace: Namespace.ID
    var isHighlighted: Bool

    @Environment(DeckStore.self) private var store
    @State private var hovering = false

    /// Room reserved in the flattened content for the live overlays.
    private static let elapsedWidth: CGFloat = 64
    private static let trailingWidth: CGFloat = 108

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(color: task.status.color, pulsing: task.status == .running, size: 9)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(task.title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                    .matchedGeometryEffect(id: "title-\(task.id)", in: namespace, properties: .position)
                Spacer(minLength: 8)
                Color.clear.frame(width: Self.elapsedWidth, height: 1)
            }

            HStack(spacing: 6) {
                Label(task.projectName, systemImage: "folder")
                    .lineLimit(1)
                if let branch = task.gitBranch, !branch.isEmpty, branch != "HEAD" {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ModelBadge(model: task.mainModel, compact: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                AvatarStack(task: task)
                Color.clear.frame(width: Self.trailingWidth, height: 22)
            }
        }
        .padding(14)
        // Rasterize the card's static content as one GPU-backed layer. On macOS SwiftUI
        // otherwise redraws the whole card on the CPU whenever anything in it changes.
        // The once-a-second timers live in small overlays outside it, so a clock tick
        // redraws only them.
        .drawingGroup()
        .overlay(alignment: .topTrailing) {
            TaskElapsedText(task: task)
                .foregroundStyle(.secondary)
                .padding(.top, 15)
                .padding(.trailing, 14)
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if task.status == .waiting {
                    Label("Waiting on you", systemImage: "hand.raised.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    TaskETAText(task: task)
                }
            }
            .lineLimit(1)
            .frame(height: 22)
            .padding(14)
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
                .matchedGeometryEffect(id: "card-\(task.id)", in: namespace)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isHighlighted ? Color.accentColor : Color.primary.opacity(hovering ? 0.16 : 0.07),
                              lineWidth: isHighlighted ? 2 : 1)
        }
        .scaleEffect(hovering ? 1.005 : 1)
        .animation(Theme.snappy, value: hovering)
        .onHover { hovering = $0 }
        .contentShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// As many agent avatars as fit (up to 12), then "+N". The count comes from the measured
/// width, so there's a single row to update (no ViewThatFits candidates).
struct AvatarStack: View {
    var task: TaskModel
    @State private var fit = 12

    private static let step: CGFloat = 18      // 22pt avatar overlapped by 4pt
    private static let moreWidth: CGFloat = 36

    var body: some View {
        let runs = task.runs
        let limit = runs.count > fit ? max(1, fit - 1) : fit
        HStack(spacing: -4) {
            ForEach(runs.prefix(limit)) { run in
                AgentAvatar(run: run, size: 22, pulsing: false)
                    .transition(.scale.combined(with: .opacity))
            }
            if runs.count > limit {
                Text("+\(runs.count - limit)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 22)
                    .background(.quaternary, in: .capsule)
                    .padding(.leading, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Int.self) { proxy in
            Int((proxy.size.width - Self.moreWidth + 4) / Self.step)
        } action: { n in
            fit = min(12, max(2, n))
        }
        .animation(Theme.spring, value: task.runIDs)
    }
}
