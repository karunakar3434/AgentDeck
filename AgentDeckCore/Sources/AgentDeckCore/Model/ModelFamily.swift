import Foundation

/// The Claude model family a model id belongs to. Drives badge hue and filtering.
public enum ModelFamily: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case fable, opus, sonnet, haiku, other

    public init(modelID: String?) {
        guard let id = modelID?.lowercased() else { self = .other; return }
        if id.contains("fable") { self = .fable }
        else if id.contains("opus") { self = .opus }
        else if id.contains("sonnet") { self = .sonnet }
        else if id.contains("haiku") { self = .haiku }
        else { self = .other }
    }

    public var displayName: String {
        switch self {
        case .fable: "Fable"
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        case .other: "Other"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Short, human label for a model id: "claude-opus-4-7" → "Opus 4.7",
/// "claude-haiku-4-5-20251001" → "Haiku 4.5", "sonnet" → "Sonnet".
public enum ModelName {
    public static func short(_ modelID: String) -> String {
        // Drop a context-window suffix such as "[1m]".
        let id = String(modelID.lowercased().prefix { $0 != "[" })
        let family = ModelFamily(modelID: id)
        guard family != .other else { return modelID }
        // Collect the version digits that follow the family name, dropping date stamps.
        guard let range = id.range(of: family.rawValue) else { return family.displayName }
        let tail = String(id[range.upperBound...])
        var parts: [String] = []
        for piece in tail.split(separator: "-") where parts.count < 2 {
            let digits = String(piece)
            if !digits.isEmpty, digits.count <= 2, digits.allSatisfy(\.isNumber) { parts.append(digits) }
        }
        if parts.isEmpty { return family.displayName }
        let version: String = parts.joined(separator: ".")
        return family.displayName + " " + version
    }
}
