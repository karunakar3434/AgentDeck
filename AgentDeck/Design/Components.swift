import SwiftUI
import AgentDeckCore
import AgentDeckState

/// A colored status dot. Running dots breathe gently unless Reduce Motion is on.
///
/// The pulse itself is drawn by the nearest `.pulseHost()` above this view, so content
/// containing dots can be flattened with `.drawingGroup()` (GPU) while the ring keeps
/// animating in the render server.
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    var size: CGFloat = 8

    var body: some View {
        if pulsing {
            PulsingDot(color: color, size: size)
        } else {
            Circle().fill(color).frame(width: size, height: size)
        }
    }
}

/// A dot that publishes its position so the nearest `.pulseHost()` draws its ring.
private struct PulsingDot: View {
    var color: Color
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseID = UUID()

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .anchorPreference(key: PulseAnchors.self, value: .bounds) { anchor in
                !reduceMotion && !Experiments.has("nopulse")
                    ? [PulseAnchors.Item(id: pulseID, anchor: anchor, color: color)] : []
            }
    }
}

struct PulseAnchors: PreferenceKey {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let anchor: Anchor<CGRect>
        let color: Color
    }
    static let defaultValue: [Item] = []
    static func reduce(value: inout [Item], nextValue: () -> [Item]) { value.append(contentsOf: nextValue()) }
}

extension View {
    /// Draws the pulse rings for every pulsing `StatusDot` inside this view, on top of it,
    /// and stops them from reaching an outer host. Hosts sit inside scroll views, so
    /// scrolling moves the rings with their layer instead of repositioning each one.
    func pulseHost() -> some View {
        overlayPreferenceValue(PulseAnchors.self) { items in
            GeometryReader { geo in
                ForEach(items) { item in
                    let r = geo[item.anchor]
                    PulseRing(color: item.color)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
            }
            .allowsHitTesting(false)
            .clipped()
        }
        .transformPreference(PulseAnchors.self) { $0 = [] }
    }
}

/// An expanding, fading ring driven by a Core Animation layer animation, so it runs in
/// the render server with no per-frame work on the main thread (hundreds stay cheap).
struct PulseRing: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> PulseRingView { PulseRingView() }

    func updateNSView(_ view: PulseRingView, context: Context) {
        let resolved = color.resolve(in: context.environment)
        view.setColor(CGColor(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green),
                              blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity)))
    }
}

final class PulseRingView: NSView {
    private let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.fillColor = nil
        ring.lineWidth = 1.5
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setColor(_ color: CGColor) {
        if ring.strokeColor != color { ring.strokeColor = color }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ring.removeAllAnimations()
        guard window != nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.6
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        ring.opacity = 0
        ring.add(group, forKey: "pulse")
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
    /// Tooltips cost an update per avatar; the dense card strip turns them off.
    var showsHelp = true

    var body: some View {
        if showsHelp { avatar.help("\(run.displayName): \(run.description)") } else { avatar }
    }

    /// Reads only near-static run fields; the status lives in `RunStatusDot`, so a status
    /// change re-evaluates one small circle instead of the symbol image and backgrounds.
    private var avatar: some View {
        let tint = AgentGlyph.color(for: run.agentType, isMain: run.isMain)
        return Image(systemName: AgentGlyph.symbol(for: run.agentType, isMain: run.isMain))
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
                RunStatusDot(run: run, pulsing: pulsing, size: size * 0.34)
                    .offset(x: 1, y: 1)
            }
    }
}

private struct RunStatusDot: View {
    var run: RunModel
    var pulsing: Bool
    var size: CGFloat

    var body: some View {
        StatusDot(color: run.status.color, pulsing: pulsing && run.status == .running, size: size)
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
    }
}

/// Stable per-agent-type symbol and tint.
enum AgentGlyph {
    private static var symbols: [String: String] = [:]

    static func symbol(for type: String, isMain: Bool) -> String {
        if isMain { return "sparkle" }
        if let s = symbols[type] { return s }
        let s = resolveSymbol(type)
        symbols[type] = s
        return s
    }

    private static func resolveSymbol(_ type: String) -> String {
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
