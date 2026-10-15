import SwiftUI
import Charts
import AgentDeckCore
import AgentDeckState

/// Gantt-style timeline of a task's runs with a "now" line. Click a bar to inspect.
struct TimelineChart: View {
    var task: TaskModel
    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    private struct Bar: Identifiable {
        let id: String
        let label: String
        let start: Date
        let end: Date
        let estimateEnd: Date?
        let color: Color
        let isSelected: Bool
    }

    var body: some View {
        // A minutes-wide Gantt chart doesn't need per-second precision; Charts rebuilds are costly.
        let now = Clock.shared.coarseNow
        let runs = store.runs(of: task)
        let selected = nav.selectedRunID
        let bars = runs.enumerated().map { i, r in
            Bar(
                id: r.id,
                label: "\(i == 0 ? "Main" : r.agentType) · \(r.id.suffix(4))",
                start: r.startedAt,
                end: max(r.endedAt ?? now, r.startedAt.addingTimeInterval(1)),
                estimateEnd: r.isMain || r.status.isFinished ? nil : r.expectedEnd,
                color: r.status.color,
                isSelected: selected == r.id
            )
        }
        let domainStart = task.startedAt
        let domainEnd = max(task.endedAt ?? now, bars.map(\.end).max() ?? now, bars.compactMap(\.estimateEnd).max() ?? now)
            .addingTimeInterval(5)

        Chart {
            ForEach(bars) { bar in
                if let est = bar.estimateEnd, est > bar.end {
                    BarMark(xStart: .value("Start", bar.end), xEnd: .value("Estimate", est), y: .value("Agent", bar.label))
                        .foregroundStyle(bar.color.opacity(0.12))
                        .cornerRadius(4)
                }
                BarMark(xStart: .value("Start", bar.start), xEnd: .value("End", bar.end), y: .value("Agent", bar.label))
                    .foregroundStyle(bar.color.gradient)
                    .cornerRadius(4)
                    .opacity(selected == nil || bar.isSelected ? 1 : 0.55)
            }
            if task.endedAt == nil {
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text("now").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    }
            }
        }
        .chartXScale(domain: domainStart...domainEnd)
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let s = value.as(String.self) {
                        Text(s.components(separatedBy: " · ").first ?? s)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text("+" + DurationText.short(d.timeIntervalSince(domainStart)))
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(.rect)
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let origin = geo[plot].origin
                        let y = location.y - origin.y
                        if let label: String = proxy.value(atY: y),
                           let bar = bars.first(where: { $0.label == label }) {
                            nav.inspect(bar.id, in: task.id)
                        }
                    }
            }
        }
        .frame(height: max(80, CGFloat(bars.count) * 24 + 40))
        .padding(.top, 14)   // room for the "now" label inside the flattened layer's bounds
        .drawingGroup()
    }
}
