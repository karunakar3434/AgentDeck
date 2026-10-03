import Foundation

/// Which model a run used (architecture §8, data-sources §4). First hit wins:
/// 1. the run's own latest non-synthetic `message.model` → `.transcript`
/// 2. `toolUseResult.resolvedModel` → `.transcript`
/// 3. the call's `model` parameter, else `meta.json` `model` unless "inherit" → `.callParameter`
/// 4. the agent definition's `model:` unless "inherit" (project, then user) → `.definition`
/// 5. inherits the parent → `ModelInfo(id: nil, source: .inherited)`
enum ModelResolver {
    struct Resolution: Sendable, Equatable {
        var model: ModelInfo
        /// Step 4 was consulted (the session must be re-dirtied when definitions change).
        var usedDefinitions: Bool
    }

    static func resolve(_ run: RunState, isMain: Bool,
                        definitionModel: (_ agentType: String) -> String?) -> Resolution {
        if let m = run.own.transcriptModel { return Resolution(model: ModelInfo(id: m, source: .transcript), usedDefinitions: false) }
        if isMain { return Resolution(model: ModelInfo(id: nil, source: .inherited), usedDefinitions: false) }
        if let m = run.resolvedModel { return Resolution(model: ModelInfo(id: m, source: .transcript), usedDefinitions: false) }
        if let m = usable(run.callModel) ?? usable(run.metaModel) {
            return Resolution(model: ModelInfo(id: m, source: .callParameter), usedDefinitions: false)
        }
        if let m = usable(definitionModel(run.agentType)) {
            return Resolution(model: ModelInfo(id: m, source: .definition), usedDefinitions: true)
        }
        return Resolution(model: ModelInfo(id: nil, source: .inherited), usedDefinitions: true)
    }

    private static func usable(_ model: String?) -> String? {
        guard let m = model?.trimmingCharacters(in: .whitespaces), !m.isEmpty, m.lowercased() != "inherit" else { return nil }
        return m
    }
}
