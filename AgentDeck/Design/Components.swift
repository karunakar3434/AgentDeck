import SwiftUI
import AgentDeckCore

/// A colored status dot. Running dots breathe gently unless Reduce Motion is on.
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if pulsing && !reduceMotion {
                    PulseHalo(color: color, size: size)
                }
            }
    }
}

private struct PulseHalo: View {
    var color: Color
    var size: CGFloat
    @State private var on = false

    var body: some View {
        Circle()
            .stroke(color.opacity(on ? 0 : 0.55), lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(on ? 2.2 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true }
            }
            .allowsHitTesting(false)
    }
}

/// A capsule badge tinted by model family: "Opus 4.7".
struct ModelBadge: View {
    var model: ModelInfo
    var parentModel: ModelInfo? = nil
    var compact = false

    private var resolved: ModelInfo {
        if model.id == nil, let parentModel, parentModel.id != nil { return parentModel }
        return model
    }

    var body: some View {
        let m = resolved
        let tint = m.family.color
        HStack(spacing: 3) {
            if !compact {
                Image(systemName: "cpu").imageScale(.small)
            }
            Text(m.id == nil ? "inherit" : m.displayName)
                .lineLimit(1)
            if model.id == nil && parentModel != nil && !compact {
                Text("inherited").foregroundStyle(.secondary)
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
        .help(helpText(m))
    }

    private func helpText(_ m: ModelInfo) -> String {
        let id = m.id ?? "unknown"
        switch model.source {
        case .transcript: return "\(id) — from the agent's transcript"
        case .callParameter: return "\(id) — from the Agent call's model parameter"
        case .definition: return "\(id) — from the agent definition"
        case .inherited: return model.id == nil ? "Inherits the parent's model (\(id))" : "\(id) — inherited"
        }
    }
}

/// A ring showing elapsed time against the estimate. Turns orange once over.
struct ProgressRing: View {
    var progress: Double?
    var color: Color
    var isOver: Bool
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(isOver ? Color.orange : color, style: .init(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: progress)
            }
        }
    }
}

/// A thin capsule progress bar.
struct ProgressBar: View {
    var progress: Double
    var color: Color
    var height: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(color)
                        .frame(width: max(height, geo.size.width * progress))
                        .animation(.linear(duration: 0.9), value: progress)
                }
            }
            .clipShape(.capsule)
    }
}

/// Small agent avatar: a symbol in a tinted circle with a status dot.
struct AgentAvatar: View {
    var run: RunModel
    var size: CGFloat = 22
    /// Running agents breathe; dense lists (task cards) turn it off to keep animation cost flat.
    var pulsing = true

    var body: some View {
        let tint = AgentGlyph.color(for: run.agentType, isMain: run.isMain)
        Image(systemName: AgentGlyph.symbol(for: run.agentType, isMain: run.isMain))
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background {
                // Opaque so overlapping avatars in a stack stay crisp.
                Circle().fill(.background)
                    .overlay(Circle().fill(tint.opacity(0.16)))
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            }
            .overlay(alignment: .bottomTrailing) {
                StatusDot(color: run.status.color, pulsing: pulsing && run.status == .running, size: size * 0.34)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    .offset(x: 1, y: 1)
            }
            .help("\(run.displayName): \(run.description)")
    }
}

/// Stable per-agent-type symbol and tint.
enum AgentGlyph {
    static func symbol(for type: String, isMain: Bool) -> String {
        if isMain { return "sparkle" }
        switch type.lowercased() {
        case "explore": return "binoculars.fill"
        case "plan": return "map.fill"
        case "general-purpose": return "square.stack.3d.up.fill"
        case "claude-code-guide": return "book.fill"
        case "code-reviewer": return "checklist"
        case "code-improver": return "wand.and.stars"
        case "test-writer": return "testtube.2"
        case "software-engineer": return "hammer.fill"
        case "system-architect": return "building.columns.fill"
        case "docs-writer": return "doc.text.fill"
        case "researcher": return "magnifyingglass"
        case "product-manager": return "chart.bar.doc.horizontal.fill"
        default: return "person.crop.circle.fill"
        }
    }

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .mint, .cyan, .brown]

    static func color(for type: String, isMain: Bool) -> Color {
        if isMain { return .accentColor }
        var h: UInt32 = 2166136261
        for b in type.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return palette[Int(h % UInt32(palette.count))]
    }
}
