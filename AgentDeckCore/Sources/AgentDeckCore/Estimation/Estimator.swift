import Foundation

/// The duration of one run that finished `done`, used to estimate later runs of the same agent type.
struct DurationSample: Sendable, Hashable {
    var agentType: String
    var family: ModelFamily
    var seconds: Double
    var endedAt: Date
}

/// Duration estimates from the durations of past runs (architecture §9).
///
/// It is a pure value type. Each owner (the engine, the mock) keeps its own copy. Samples are bucketed per
/// agent type and per (agent type, model family). Each bucket keeps its newest `bucketCapacity` samples by
/// `endedAt`, so samples may arrive in any order (live runs, history, scanner batches). Medians are computed
/// when samples are added, which makes `estimate` two dictionary lookups and a little arithmetic. It is
/// called for every running run on every snapshot rebuild.
///
/// Rules for `estimate(agentType:family:)`:
/// - Bucket: the (type, family) bucket when `family != .other` and it holds at least
///   `familyMinimumSamples` samples, else the type bucket (all families).
/// - `n` = bucket count; confidence = `EstimateConfidence(sampleCount: n)` (high ≥ 10, medium 3–9, low < 3).
/// - Seconds:
///   - n ≥ 3: the median (an even count averages the two middle values).
///   - n = 0: the built-in default for the type.
///   - n = 1–2: the mean of the samples plus the default, with the default counting as one extra sample:
///     `(sum + default) / (n + 1)`. One unusual run doesn't take over the estimate, and real data still
///     moves it away from a generic default. Confidence stays `.low`.
struct Estimator: Sendable {
    /// Seconds used when a type has no samples.
    static let builtInDefaults: [String: Double] = ["Explore": 60, "Plan": 120, "general-purpose": 180]
    /// Seconds used for types without a built-in default.
    static let fallbackDefault: Double = 150
    /// Samples kept per bucket (newest by `endedAt`).
    static let bucketCapacity = 50
    /// A (type, family) bucket is used once it holds at least this many samples.
    static let familyMinimumSamples = 5
    /// Buckets with at least this many samples use their median.
    static let medianMinimumSamples = 3

    /// Bumps on every `add` call with at least one sample, for cheap change detection. 0 after `init`.
    private(set) var version: Int = 0
    private var entries: [String: TypeEntry] = [:]

    init(samples: [DurationSample] = []) {
        add(contentsOf: samples)
        version = 0
    }

    /// Adds one sample. Keeps the newest 50 per type and per (type, family). Samples with a negative or
    /// non-finite duration are ignored (the version still bumps).
    mutating func add(_ sample: DurationSample) {
        version &+= 1
        guard Self.isValid(sample) else { return }
        entries[sample.agentType, default: TypeEntry()].insert(sample)
        entries[sample.agentType]?.refreshMedians()
    }

    /// Adds a batch of samples, recomputing each touched type's medians once.
    mutating func add(contentsOf samples: [DurationSample]) {
        guard !samples.isEmpty else { return }
        version &+= 1
        var touched: Set<String> = []
        for sample in samples where Self.isValid(sample) {
            entries[sample.agentType, default: TypeEntry()].insert(sample)
            touched.insert(sample.agentType)
        }
        for type in touched {
            entries[type]?.refreshMedians()
        }
    }

    func estimate(agentType: String, family: ModelFamily) -> DurationEstimate {
        let fallback = Self.defaultSeconds(for: agentType)
        guard let entry = entries[agentType] else {
            return DurationEstimate(seconds: fallback, confidence: .low, sampleCount: 0)
        }
        if family != .other, let bucket = entry.byFamily[family], bucket.count >= Self.familyMinimumSamples {
            return bucket.estimate(defaultSeconds: fallback)
        }
        return entry.all.estimate(defaultSeconds: fallback)
    }

    /// Number of samples kept for a type (all families), or for one (type, family) bucket.
    func sampleCount(agentType: String, family: ModelFamily? = nil) -> Int {
        guard let entry = entries[agentType] else { return 0 }
        guard let family else { return entry.all.count }
        return entry.byFamily[family]?.count ?? 0
    }

    static func defaultSeconds(for agentType: String) -> Double {
        builtInDefaults[agentType] ?? fallbackDefault
    }

    /// Median of `values`; the mean of the two middle values for an even count; 0 when empty.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func isValid(_ sample: DurationSample) -> Bool {
        sample.seconds.isFinite && sample.seconds >= 0
    }
}

extension Estimator {
    /// All buckets of one agent type. `.other` gets no family bucket (it always uses the type bucket).
    private struct TypeEntry: Sendable {
        var all = Bucket()
        var byFamily: [ModelFamily: Bucket] = [:]

        mutating func insert(_ sample: DurationSample) {
            all.insert(sample)
            if sample.family != .other {
                byFamily[sample.family, default: Bucket()].insert(sample)
            }
        }

        mutating func refreshMedians() {
            all.refreshMedian()
            for index in byFamily.values.indices {
                byFamily.values[index].refreshMedian()
            }
        }
    }

    /// The newest samples of one key, ascending by `endedAt`, plus their cached median.
    private struct Bucket: Sendable {
        private(set) var samples: [Sample] = []
        private var median: Double = 0
        private var medianIsStale = false

        struct Sample: Sendable {
            var seconds: Double
            var endedAt: Date
        }

        var count: Int { samples.count }

        /// Inserts in `endedAt` order (a tie goes after existing samples, so the later arrival counts as newer)
        /// and drops the oldest beyond capacity.
        mutating func insert(_ sample: DurationSample) {
            var low = 0
            var high = samples.count
            while low < high {
                let mid = (low + high) / 2
                if samples[mid].endedAt <= sample.endedAt { low = mid + 1 } else { high = mid }
            }
            let capacity = Estimator.bucketCapacity
            if samples.count >= capacity && low == 0 { return }   // older than everything kept
            samples.insert(Sample(seconds: sample.seconds, endedAt: sample.endedAt), at: low)
            if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
            medianIsStale = true
        }

        mutating func refreshMedian() {
            guard medianIsStale else { return }
            medianIsStale = false
            median = Estimator.median(samples.map(\.seconds))
        }

        func estimate(defaultSeconds: Double) -> DurationEstimate {
            let n = samples.count
            let seconds: Double
            if n >= Estimator.medianMinimumSamples {
                seconds = median
            } else if n == 0 {
                seconds = defaultSeconds
            } else {
                seconds = (samples.reduce(0) { $0 + $1.seconds } + defaultSeconds) / Double(n + 1)
            }
            return DurationEstimate(seconds: seconds, confidence: EstimateConfidence(sampleCount: n), sampleCount: n)
        }
    }
}
