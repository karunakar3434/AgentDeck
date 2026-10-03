import Foundation

/// Launch-time switches for performance experiments: AGENTDECK_EXPERIMENT=nochart,noinspector
enum Experiments {
    static let flags: Set<String> = Set(
        (ProcessInfo.processInfo.environment["AGENTDECK_EXPERIMENT"] ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    )
    static func has(_ name: String) -> Bool { flags.contains(name) }
}
