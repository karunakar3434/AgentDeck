import Foundation

/// SplitMix64: a tiny, fast generator that is fully determined by its seed,
/// so a seeded simulation replays identically.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    /// Uniform in `range` (modulo bias is negligible for the small ranges used here).
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func chance(_ probability: Double) -> Bool { unit() < probability }

    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }

    /// Picks by relative weight.
    mutating func weighted<T>(_ items: [(T, Double)]) -> T {
        let total = items.reduce(0) { $0 + $1.1 }
        var x = unit() * total
        for (item, weight) in items {
            if x < weight { return item }
            x -= weight
        }
        return items[items.count - 1].0
    }

    /// Picks by the precomputed weights.
    mutating func pick<T>(_ weights: MockWeights<T>) -> T {
        let cumulative = weights.cumulative
        let x = unit() * cumulative[cumulative.count - 1]
        var i = 0
        while i < cumulative.count - 1, x >= cumulative[i] { i += 1 }
        return weights.items[i]
    }

    // Ids. Built with the standard library's radix formatting, which stays fast in debug builds.

    /// 16 lowercase hex digits.
    mutating func hex16() -> String { String(next() | (1 << 60), radix: 16) }

    /// Shaped like an Anthropic tool_use id: "toolu_01" + 26 alphanumerics.
    mutating func toolUseID() -> String {
        "toolu_01" + String(next() | (1 << 63), radix: 36, uppercase: true) + String(next() | (1 << 63), radix: 36)
    }

    /// A lowercase UUID-shaped id, like a Claude Code session id.
    mutating func uuid() -> String {
        var hex = Array((hex16() + hex16()).utf8)
        hex[12] = UInt8(ascii: "4")
        for dash in [20, 16, 12, 8] { hex.insert(UInt8(ascii: "-"), at: dash) }
        return String(decoding: hex, as: UTF8.self)
    }
}
