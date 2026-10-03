import Foundation

/// Launch-time switches for performance experiments, e.g. AGENTDECK_EXPERIMENT=notree,noinspector.
/// Read by views: nopulse, notree, noinspector, nosidebar, nosubtitle, nomenubar, nodock.
enum Experiments {
    static let flags: Set<String> = Set(
        (ProcessInfo.processInfo.environment["AGENTDECK_EXPERIMENT"] ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    )
    static func has(_ name: String) -> Bool { flags.contains(name) }
}

