import SwiftUI
import AgentDeckCore

/// The Active view: live header strip, then one card per active task.
struct ActiveView: View {
    var taskIDs: [String]
    var namespace: Namespace.ID
    var project: String? = nil

    @Environment(DeckStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HeaderStrip(activeCount: taskIDs.count)
                        .padding(.bottom, 4)

                    if taskIDs.isEmpty {
                        ActiveEmptyState(project: project)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                            .transition(.opacity)
                    }

                    ForEach(taskIDs, id: \.self) { id in
                        if let task = store.tasks[id] {
                            TaskCard(task: task, namespace: namespace, isHighlighted: nav.highlightedTaskID == id)
                                .id(id)
                                .onTapGesture { nav.openTask(id) }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity.combined(with: .scale(scale: 0.96))
                                ))
                        }
                    }
                }
                .padding(16)
                .animation(Theme.spring, value: taskIDs)
            }
            .onChange(of: nav.highlightedTaskID) { _, id in
                guard let id else { return }
                withAnimation(Theme.snappy) { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }
}

struct ActiveEmptyState: View {
    var project: String?
    @Environment(DeckStore.self) private var store

    var body: some View {
        if !store.initialLoadComplete {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading Claude Code sessions…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let error = store.loadError {
            ContentUnavailableView {
                Label("Can't read sessions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else {
            ContentUnavailableView {
                Label("No agents running", systemImage: "moon.stars")
            } description: {
                if let last = store.lastFinishedAt {
                    HStack(spacing: 3) {
                        Text("Last task finished")
                        AgoText(date: last)
                    }
                } else if let project {
                    Text("Nothing is running in \(project).")
                } else {
                    Text("Start a Claude Code session and it will show up here.")
                }
            }
        }
    }
}
