import Foundation
import Testing
@testable import AgentDeckCore

@Suite struct EstimatorTests {
    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Samples of one type and family, ending 1 s apart (in the given order) after `start`.
    private func samples(_ type: String = "Explore", _ family: ModelFamily = .opus, _ seconds: [Double],
                         start: TimeInterval = 0) -> [DurationSample] {
        seconds.enumerated().map { index, value in
            DurationSample(agentType: type, family: family, seconds: value,
                           endedAt: Self.base.addingTimeInterval(start + Double(index)))
        }
    }

    // MARK: Defaults and small counts

    @Test(arguments: [("Explore", 60.0), ("Plan", 120.0), ("general-purpose", 180.0), ("localbiz-qa", 150.0)])
    func noSamplesUsesTheTypeDefault(type: String, seconds: Double) {
        let estimator = Estimator(samples: samples("Other", .opus, [10, 20, 30]))
        for family in ModelFamily.allCases {
            let estimate = estimator.estimate(agentType: type, family: family)
            #expect(estimate == DurationEstimate(seconds: seconds, confidence: .low, sampleCount: 0))
        }
    }

    @Test func builtInDefaultsMatchTheSpec() {
        #expect(Estimator.builtInDefaults == ["Explore": 60, "Plan": 120, "general-purpose": 180])
        #expect(Estimator.fallbackDefault == 150)
    }

    @Test func oneOrTwoSamplesBlendWithTheDefault() {
        // n = 1: (120 + 60) / 2
        let one = Estimator(samples: samples("Explore", .opus, [120]))
        #expect(one.estimate(agentType: "Explore", family: .opus)
                == DurationEstimate(seconds: 90, confidence: .low, sampleCount: 1))
        // n = 2: (120 + 180 + 60) / 3
        let two = Estimator(samples: samples("Explore", .opus, [120, 180]))
        #expect(two.estimate(agentType: "Explore", family: .opus)
                == DurationEstimate(seconds: 120, confidence: .low, sampleCount: 2))
        // Unknown type blends with the fallback default: (50 + 150) / 2
        let custom = Estimator(samples: samples("localbiz-qa", .sonnet, [50]))
        #expect(custom.estimate(agentType: "localbiz-qa", family: .sonnet).seconds == 100)
    }

    // MARK: Confidence and median

    @Test(arguments: [(2, EstimateConfidence.low), (3, .medium), (9, .medium), (10, .high)])
    func confidenceBoundaries(count: Int, confidence: EstimateConfidence) {
        let estimator = Estimator(samples: samples("Plan", .opus, Array(repeating: 100, count: count)))
        let estimate = estimator.estimate(agentType: "Plan", family: .opus)
        #expect(estimate.confidence == confidence)
        #expect(estimate.sampleCount == count)
        #expect(estimate.isApproximate == (confidence == .low))
        if count >= 3 { #expect(estimate.seconds == 100) }
    }

    @Test func medianOfOddAndEvenCounts() {
        #expect(Estimator.median([5, 1, 3]) == 3)
        #expect(Estimator.median([4, 1, 3, 2]) == 2.5)
        #expect(Estimator.median([7]) == 7)
        #expect(Estimator.median([]) == 0)

        let odd = Estimator(samples: samples("Explore", .opus, [50, 10, 30, 1000, 20]))
        #expect(odd.estimate(agentType: "Explore", family: .opus).seconds == 30)
        let even = Estimator(samples: samples("Explore", .opus, [40, 10, 30, 1000]))
        #expect(even.estimate(agentType: "Explore", family: .opus).seconds == 35)
    }

    // MARK: Buckets

    @Test func familyBucketIsUsedFromFiveSamples() {
        var estimator = Estimator(samples: samples("Explore", .haiku, Array(repeating: 30, count: 10)))
        estimator.add(contentsOf: samples("Explore", .opus, Array(repeating: 300, count: 4), start: 100))

        // 4 opus samples: not enough, so the type bucket (14 samples, median 30) is used.
        #expect(estimator.estimate(agentType: "Explore", family: .opus)
                == DurationEstimate(seconds: 30, confidence: .high, sampleCount: 14))

        estimator.add(DurationSample(agentType: "Explore", family: .opus, seconds: 300,
                                     endedAt: Self.base.addingTimeInterval(200)))
        // 5 opus samples: the family bucket wins.
        #expect(estimator.estimate(agentType: "Explore", family: .opus)
                == DurationEstimate(seconds: 300, confidence: .medium, sampleCount: 5))
        #expect(estimator.estimate(agentType: "Explore", family: .haiku)
                == DurationEstimate(seconds: 30, confidence: .high, sampleCount: 10))
        // A family with no bucket, and `.other`, use the type bucket.
        #expect(estimator.estimate(agentType: "Explore", family: .sonnet).sampleCount == 15)
        #expect(estimator.estimate(agentType: "Explore", family: .other).sampleCount == 15)
    }

    @Test func otherFamilyNeverGetsItsOwnBucket() {
        var estimator = Estimator(samples: samples("Plan", .other, Array(repeating: 10, count: 6)))
        estimator.add(contentsOf: samples("Plan", .opus, Array(repeating: 500, count: 7), start: 100))
        #expect(estimator.sampleCount(agentType: "Plan", family: .other) == 0)
        // `.other` uses the type bucket: 13 samples, median 500.
        #expect(estimator.estimate(agentType: "Plan", family: .other)
                == DurationEstimate(seconds: 500, confidence: .high, sampleCount: 13))
    }

    @Test func keepsTheNewestFiftyByEndedAt() {
        // seconds == index, ending in increasing order: the newest 50 are 10...59.
        var estimator = Estimator(samples: samples("Explore", .opus, (0..<60).map(Double.init)))
        #expect(estimator.sampleCount(agentType: "Explore") == 50)
        #expect(estimator.sampleCount(agentType: "Explore", family: .opus) == 50)
        #expect(estimator.estimate(agentType: "Explore", family: .opus).seconds == 34.5)

        // Older than everything kept: dropped.
        estimator.add(DurationSample(agentType: "Explore", family: .opus, seconds: 1000,
                                     endedAt: Self.base.addingTimeInterval(-1)))
        #expect(estimator.estimate(agentType: "Explore", family: .opus).seconds == 34.5)

        // Newest: evicts 10, so the values are 11...59 plus 1000.
        estimator.add(DurationSample(agentType: "Explore", family: .opus, seconds: 1000,
                                     endedAt: Self.base.addingTimeInterval(1000)))
        #expect(estimator.sampleCount(agentType: "Explore") == 50)
        #expect(estimator.estimate(agentType: "Explore", family: .opus).seconds == 35.5)
    }

    @Test func typeAndFamilyCapsAreIndependent() {
        // 50 newer haiku samples push the 30 older opus samples out of the type bucket,
        // but the opus bucket keeps them.
        var estimator = Estimator(samples: samples("Explore", .opus, Array(repeating: 400, count: 30)))
        estimator.add(contentsOf: samples("Explore", .haiku, Array(repeating: 20, count: 50), start: 100))
        #expect(estimator.sampleCount(agentType: "Explore") == 50)
        #expect(estimator.estimate(agentType: "Explore", family: .other).seconds == 20)
        #expect(estimator.estimate(agentType: "Explore", family: .opus)
                == DurationEstimate(seconds: 400, confidence: .high, sampleCount: 30))
    }

    @Test func batchAndSingleAddsAgree() {
        // Distinct end times (ties would make eviction order depend on arrival order).
        let endOffsets = (0..<300).shuffled()
        let all = (0..<300).map { index in
            DurationSample(agentType: ["Explore", "Plan", "x"][index % 3],
                           family: ModelFamily.allCases[index % ModelFamily.allCases.count],
                           seconds: Double(Int.random(in: 1...600)),
                           endedAt: Self.base.addingTimeInterval(Double(endOffsets[index])))
        }
        let batch = Estimator(samples: all.shuffled())
        var single = Estimator()
        for sample in all { single.add(sample) }
        for type in ["Explore", "Plan", "x", "missing"] {
            for family in ModelFamily.allCases {
                #expect(batch.estimate(agentType: type, family: family)
                        == single.estimate(agentType: type, family: family))
            }
        }
    }

    @Test func invalidDurationsAreIgnored() {
        var estimator = Estimator()
        estimator.add(contentsOf: [
            DurationSample(agentType: "Plan", family: .opus, seconds: -1, endedAt: Self.base),
            DurationSample(agentType: "Plan", family: .opus, seconds: .nan, endedAt: Self.base),
            DurationSample(agentType: "Plan", family: .opus, seconds: .infinity, endedAt: Self.base),
        ])
        #expect(estimator.sampleCount(agentType: "Plan") == 0)
        #expect(estimator.estimate(agentType: "Plan", family: .opus).seconds == 120)
    }

    // MARK: Version

    @Test func versionBumpsOnEveryAdd() {
        var estimator = Estimator(samples: samples("Explore", .opus, [1, 2, 3]))
        #expect(estimator.version == 0)
        estimator.add(DurationSample(agentType: "Explore", family: .opus, seconds: 4, endedAt: Self.base))
        #expect(estimator.version == 1)
        estimator.add(contentsOf: samples("Plan", .haiku, [5, 6]))
        #expect(estimator.version == 2)
        estimator.add(contentsOf: [])
        #expect(estimator.version == 2)
        // A sample that is dropped (older than a full bucket, or invalid) still counts as an add.
        estimator.add(DurationSample(agentType: "Explore", family: .opus, seconds: -5, endedAt: Self.base))
        #expect(estimator.version == 3)
    }
}
