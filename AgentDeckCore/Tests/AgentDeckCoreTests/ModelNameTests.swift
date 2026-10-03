import Testing
@testable import AgentDeckCore

@Suite struct ModelNameTests {
    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-sonnet-4-6", "Sonnet 4.6"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-opus-4-7[1m]", "Opus 4.7"),
        ("sonnet", "Sonnet"),
        ("<synthetic>", "<synthetic>"),
    ])
    func shortNames(id: String, expected: String) {
        #expect(ModelName.short(id) == expected)
    }

    @Test func families() {
        #expect(ModelFamily(modelID: "claude-haiku-4-5-20251001") == .haiku)
        #expect(ModelFamily(modelID: nil) == .other)
        #expect(ModelFamily(modelID: "claude-fable-5-1") == .fable)
    }
}
