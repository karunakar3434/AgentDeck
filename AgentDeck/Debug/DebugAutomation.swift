#if DEBUG
import SwiftUI
import AppKit
import AgentDeckCore

/// Debug-only remote control so the app can be driven and screenshotted from the
/// command line without Screen Recording or Accessibility permissions.
///
/// `scripts/debugctl <command> [args…]` posts a distributed notification named
/// `com.karun.AgentDeck.debug` with `userInfo["args"]`. Snapshots are rendered by the
/// app itself (`cacheDisplay`), so they need no capture permission.
@MainActor
enum DebugAutomation {
    private static var observer: NSObjectProtocol?

    static func install(app: AppModel) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.karun.AgentDeck.debug"), object: nil, queue: .main
        ) { note in
            let args = (note.userInfo?["args"] as? [String]) ?? []
            MainActor.assumeIsolated { run(args, app: app) }
        }
    }

    private static func run(_ args: [String], app: AppModel) {
        guard let cmd = args.first else { return }
        let rest = Array(args.dropFirst())
        let nav = app.nav, store = app.store
        switch cmd {
        case "snapshot":
            snapshot(window: rest.count > 1 ? rest[1] : "main", to: rest.first ?? "/tmp/agentdeck.png", app: app)
        case "section":
            switch rest.first ?? "active" {
            case "history": nav.show(.history)
            case "active": nav.show(.active)
            default: nav.show(.project(rest.dropFirst().joined(separator: " ")))
            }
        case "open":
            let ids = TaskQuery.ids(for: nav.section, store: store, nav: nav)
            let i = Int(rest.first ?? "0") ?? 0
            if ids.indices.contains(i) { nav.openTask(ids[i]) }
        case "close":
            nav.closeTask()
        case "inspect":
            if let open = nav.openTaskID, let t = store.tasks[open] {
                let i = Int(rest.first ?? "1") ?? 1
                if t.runIDs.indices.contains(i) { nav.inspect(t.runIDs[i], in: open) }
            }
        case "inspector":
            withAnimation(Theme.spring) { nav.showInspector = rest.first != "off" }
        case "palette":
            withAnimation(Theme.spring) { nav.showPalette = rest.first != "off" }
        case "search":
            nav.searchText = rest.joined(separator: " ")
        case "highlight":
            let ids = TaskQuery.ids(for: nav.section, store: store, nav: nav)
            let i = Int(rest.first ?? "0") ?? 0
            if ids.indices.contains(i) { nav.highlightedTaskID = ids[i] }
        case "filter":
            // filter status running | filter model opus | filter clear
            switch rest.first {
            case "status": if let s = TaskStatus(rawValue: rest.last ?? "") { nav.filters.taskStatuses.insert(s) }
            case "model": if let m = ModelFamily(rawValue: rest.last ?? "") { nav.filters.models.insert(m) }
            default: nav.filters = Filters()
            }
        case "resize":
            if let w = mainWindow(), rest.count == 2, let width = Double(rest[0]), let height = Double(rest[1]) {
                var f = w.frame
                f.origin.y += f.height - height
                f.size = CGSize(width: width, height: height)
                w.setFrame(f, display: true, animate: false)
            }
        case "appearance":
            NSApp.appearance = rest.first == "dark" ? NSAppearance(named: .darkAqua)
                : rest.first == "light" ? NSAppearance(named: .aqua) : nil
        case "mock":
            app.setMock(rest.first != "off", stress: rest.first == "stress")
        case "settings":
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "state":
            let path = rest.first ?? "/tmp/agentdeck-state.txt"
            let s = """
            active=\(store.activeTaskIDs.count) inactive=\(store.inactiveTaskIDs.count) running=\(store.runningAgentCount) \
            runs=\(store.runs.count) section=\(nav.section.title) open=\(nav.openTaskID ?? "-") inspect=\(nav.inspectedRunID ?? "-") \
            loaded=\(store.initialLoadComplete) error=\(store.loadError ?? "-")
            """
            try? s.write(toFile: path, atomically: true, encoding: .utf8)
        case "dump":
            let path = rest.first ?? "/tmp/agentdeck-dump.txt"
            var lines: [String] = []
            for id in store.activeTaskIDs + store.inactiveTaskIDs {
                guard let t = store.tasks[id] else { continue }
                lines.append("TASK \(t.status.rawValue) \(t.projectName) | \(t.title) | model=\(t.mainModel.id ?? "-") runs=\(t.runIDs.count)")
                for rid in t.runIDs {
                    guard let r = store.runs[rid] else { continue }
                    let est = r.estimate.map { "\(Int($0.seconds))s/\($0.confidence.rawValue)/\($0.sampleCount)" } ?? "-"
                    lines.append("  RUN \(r.status.rawValue) d=\(r.depth) \(r.agentType) | \(r.description) | model=\(r.model.id ?? "nil")(\(r.model.source.rawValue)) elapsed=\(Int(r.elapsed(at: Date())))s est=\(est) tools=\(r.toolCallCount) act=\(r.currentActivity ?? "-")")
                }
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        case "snapview":
            // snapview <class-substring> <path>: cacheDisplay one view by class name
            var found: NSView?
            func find(_ v: NSView) {
                if found == nil, String(describing: type(of: v)).contains(rest.first ?? "") { found = v; return }
                for s in v.subviews { find(s) }
            }
            if let root = mainWindow()?.contentView?.superview { find(root) }
            if let v = found, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: rest.last ?? "/tmp/v.png"))
            }
        case "views":
            // Dump the AppKit view tree (class, frame, row counts) to check what cacheDisplay can't draw.
            var out: [String] = []
            func walk(_ v: NSView, _ depth: Int) {
                var line = String(repeating: "  ", count: depth) + "\(type(of: v)) \(Int(v.frame.minX)),\(Int(v.frame.minY)) \(Int(v.frame.width))x\(Int(v.frame.height))"
                if let t = v as? NSTableView { line += " rows=\(t.numberOfRows)" }
                if v.isHidden { line += " hidden" }
                out.append(line)
                if depth < 40 { for s in v.subviews { walk(s, depth + 1) } }
            }
            if let root = mainWindow()?.contentView?.superview { walk(root, 0) }
            try? out.joined(separator: "\n").write(toFile: rest.first ?? "/tmp/agentdeck-views.txt", atomically: true, encoding: .utf8)
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    /// Renders a window (frame view included, so the toolbar shows) to a PNG.
    private static func snapshot(window kind: String, to path: String, app: AppModel) {
        if kind == "popover" {
            let view = MenuBarPopover()
                .environment(app).environment(app.store).environment(app.nav)
                .background(.background)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            return
        }
        let window: NSWindow?
        if kind == "settings" {
            window = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
                ?? NSApp.windows.first { $0.isVisible && $0.title.contains("Settings") }
        } else {
            window = mainWindow()
        }
        guard let root = window?.contentView?.superview ?? window?.contentView else { return }
        let bounds = root.bounds
        guard let base = root.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        root.cacheDisplay(in: bounds, to: base)

        // cacheDisplay of the whole window skips table views hosted inside NSGlassEffectView
        // (the sidebar list), so draw those tables directly on top, on a material-like fill.
        var tables: [NSTableView] = []
        func collect(_ v: NSView, inGlass: Bool) {
            let glass = inGlass || String(describing: type(of: v)) == "NSGlassEffectView"
            if glass, let t = v as? NSTableView, !t.isHiddenOrHasHiddenAncestor { tables.append(t) }
            for s in v.subviews { collect(s, inGlass: glass) }
        }
        collect(root, inGlass: false)

        let image = NSImage(size: bounds.size)
        image.lockFocusFlipped(root.isFlipped)
        base.draw(in: bounds)
        let dark = root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for t in tables {
            let visible = t.visibleRect
            guard visible.width > 1, visible.height > 1 else { continue }
            let area = (t.enclosingScrollView ?? t).convert((t.enclosingScrollView ?? t).bounds, to: root)
            (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.955, alpha: 1)).setFill()
            NSBezierPath(rect: area).fill()
            for row in t.selectedRowIndexes where row < t.numberOfRows {
                let r = t.convert(t.rect(ofRow: row).insetBy(dx: 10, dy: 0), to: root)
                NSColor.controlAccentColor.withAlphaComponent(dark ? 0.45 : 0.22).setFill()
                NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            }
            // Selection materials render black through cacheDisplay; hide them for the capture.
            var hidden: [NSView] = []
            func hideEffects(_ v: NSView) {
                if v is NSVisualEffectView, !v.isHidden { v.isHidden = true; hidden.append(v) }
                for s in v.subviews { hideEffects(s) }
            }
            hideEffects(t)
            if let rep = t.bitmapImageRepForCachingDisplay(in: visible) {
                t.cacheDisplay(in: visible, to: rep)
                rep.draw(in: t.convert(visible, to: root), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
            }
            hidden.forEach { $0.isHidden = false }
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
