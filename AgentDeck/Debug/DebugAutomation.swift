import SwiftUI
import AppKit
import AgentDeckCore

/// Remote control so the app can be driven and screenshotted from the command line
/// without Screen Recording or Accessibility permissions. Active in Debug builds, and in
/// Release builds launched with `-automation` (used for Instruments profiling).
///
/// `scripts/debugctl <command> [args…]` posts a distributed notification named
/// `com.karun.AgentDeck.debug` with `userInfo["args"]`. Snapshots are rendered by the
/// app itself (`cacheDisplay`), so they need no capture permission.
@MainActor
enum DebugAutomation {
    private static var observer: NSObjectProtocol?

    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        CommandLine.arguments.contains("-automation")
        #endif
    }

    static func install(app: AppModel) {
        guard isEnabled, observer == nil else { return }
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
        case "scroll":
            // scroll <dy> [x y]: synthesize a scroll-wheel event in the main window (in-process, no permissions).
            guard let w = mainWindow(), let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                       wheel1: Int32(rest.first.flatMap(Int.init) ?? -200), wheel2: 0, wheel3: 0) else { break }
            let x = rest.count > 2 ? Double(rest[1]) ?? 600 : 600, y = rest.count > 2 ? Double(rest[2]) ?? 300 : 300
            let screenPoint = w.convertPoint(toScreen: NSPoint(x: x, y: w.frame.height - y))
            let mainH = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: screenPoint.x, y: mainH - screenPoint.y)
            if let e = NSEvent(cgEvent: cg) { w.sendEvent(e) }
        case "menubar":
            let b = statusItemButton()
            try? "button=\(b.map { String(describing: type(of: $0)) } ?? "nil") action=\(b?.action.map(NSStringFromSelector) ?? "-") target=\(b?.target.map { String(describing: type(of: $0)) } ?? "-")".write(toFile: "/tmp/agentdeck-menubar.txt", atomically: true, encoding: .utf8)
            clickStatusItem()
        case "windows":
            let lines = NSApp.windows.map { w in
                "\(type(of: w)) visible=\(w.isVisible) level=\(w.level.rawValue) frame=\(w.frame) title=\(w.title) id=\(w.identifier?.rawValue ?? "-") content=\(w.contentView.map { String(describing: type(of: $0)) } ?? "-")"
            }
            try? lines.joined(separator: "\n").write(toFile: rest.first ?? "/tmp/agentdeck-windows.txt", atomically: true, encoding: .utf8)
        case "meter":
            // meter start | meter stop <path>
            if rest.first == "start", let v = mainWindow()?.contentView {
                FrameMeter.shared.start(in: v)
            } else {
                let report = FrameMeter.shared.stop()
                try? report.write(toFile: rest.count > 1 ? rest[1] : "/tmp/agentdeck-meter.txt", atomically: true, encoding: .utf8)
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
            // Host the popover view in an ordinary window (MenuBarExtra can't be opened in-process).
            let host = NSHostingView(rootView: MenuBarPopover()
                .environment(app).environment(app.store).environment(app.nav))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                write(capture(w), to: path)
                w.orderOut(nil)
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
        guard let window else { return }
        write(capture(window), to: path)
    }

    private static func statusItemButton() -> NSStatusBarButton? {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            if let b = findView(in: w.contentView, as: NSStatusBarButton.self) { return b }
        }
        return nil
    }

    /// MenuBarExtra ignores performClick, so deliver a real mouse down/up to the button's window.
    private static func clickStatusItem() {
        guard let b = statusItemButton(), let w = b.window else { return }
        let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                w.sendEvent(e)
            }
        }
    }

    private static func popoverWindow() -> NSWindow? {
        NSApp.windows.first { w in
            w.isVisible && !String(describing: type(of: w)).contains("StatusBar")
                && (w is NSPanel || String(describing: type(of: w)).contains("MenuBarExtra"))
        }
    }

    private static func findView<T: NSView>(in view: NSView?, as type: T.Type) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for s in view.subviews { if let v = findView(in: s, as: type) { return v } }
        return nil
    }

    private static func write(_ image: NSImage?, to path: String) {
        guard let image, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// Renders a window, frame view included, compositing glass-hosted scroll views.
    private static func capture(_ window: NSWindow) -> NSImage? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        let bounds = root.bounds
        guard let base = root.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        root.cacheDisplay(in: bounds, to: base)

        // cacheDisplay of the whole window skips scroll views hosted inside NSGlassEffectView
        // (the sidebar list, the inspector), so draw their documents on top on a material-like fill.
        var docs: [NSView] = []
        func collect(_ v: NSView, inGlass: Bool) {
            let glass = inGlass || String(describing: type(of: v)) == "NSGlassEffectView"
            if glass, let sv = v as? NSScrollView, !sv.isHiddenOrHasHiddenAncestor, let doc = sv.documentView {
                docs.append(doc)
                return
            }
            for s in v.subviews { collect(s, inGlass: glass) }
        }
        collect(root, inGlass: false)

        let image = NSImage(size: bounds.size)
        image.lockFocusFlipped(root.isFlipped)
        base.draw(in: bounds)
        let dark = root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for doc in docs {
            let visible = doc.visibleRect
            guard visible.width > 1, visible.height > 1, let scroll = doc.enclosingScrollView else { continue }
            let area = scroll.convert(scroll.bounds, to: root)
            (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.955, alpha: 1)).setFill()
            NSBezierPath(rect: area).fill()
            if let t = doc as? NSTableView {
                for row in t.selectedRowIndexes where row < t.numberOfRows {
                    let r = t.convert(t.rect(ofRow: row).insetBy(dx: 10, dy: 0), to: root)
                    NSColor.controlAccentColor.withAlphaComponent(dark ? 0.45 : 0.22).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
                }
            }
            // Selection materials render black through cacheDisplay; hide them for the capture.
            var hidden: [NSView] = []
            func hideEffects(_ v: NSView) {
                if v is NSVisualEffectView, !v.isHidden { v.isHidden = true; hidden.append(v) }
                for s in v.subviews { hideEffects(s) }
            }
            hideEffects(doc)
            if let rep = doc.bitmapImageRepForCachingDisplay(in: visible) {
                doc.cacheDisplay(in: visible, to: rep)
                rep.draw(in: doc.convert(visible, to: root), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
            }
            hidden.forEach { $0.isHidden = false }
        }
        image.unlockFocus()
        return image
    }
}
