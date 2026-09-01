import Foundation

public struct ScoredTake: Identifiable {
    public var id: Date { record.at }
    public let record: BakeoffRecord
    public let expected: String
    public let oursWer: Double
    /// nil when the rival's text never landed for this take.
    public let rivalWer: Double?
}

public struct EngineSummary {
    public let engineKey: String
    public let takes: Int
    public let meanOursWer: Double
    public let meanOursMs: Int
    public let meanRivalWer: Double
    public let meanRivalMs: Int
}

/// Scores a run: takes with an expected sentence, per-engine means over mutually scored takes,
/// and the verdict counts. Pure over records, so it is testable without a view.
public struct RunSummary {
    public let takes: [ScoredTake]
    public let engines: [EngineSummary]
    public let wins: Int
    public let losses: Int
    public let ties: Int
    /// Takes both sides scored.
    public var decided: Int { wins + losses + ties }

    public init(records: [BakeoffRecord]) {
        var takes: [ScoredTake] = []
        var wins = 0, losses = 0, ties = 0
        var sums: [String: (takes: Int, oursWer: Double, oursMs: Int, rivalWer: Double, rivalMs: Int)] = [:]
        for record in records {
            guard let expected = record.expected else { continue }
            let ours = Scorer.wer(reference: expected, hypothesis: record.ours)
            var rivalWer: Double?
            if case .landed(let text, let ms) = record.rival {
                let wer = Scorer.wer(reference: expected, hypothesis: text)
                rivalWer = wer
                var sum = sums[record.engine] ?? (0, 0, 0, 0, 0)
                sum.takes += 1
                sum.oursWer += ours
                sum.oursMs += record.oursMs
                sum.rivalWer += wer
                sum.rivalMs += ms
                sums[record.engine] = sum
                if ours < wer { wins += 1 } else if wer < ours { losses += 1 } else { ties += 1 }
            }
            takes.append(ScoredTake(record: record, expected: expected, oursWer: ours, rivalWer: rivalWer))
        }
        self.takes = takes
        self.wins = wins
        self.losses = losses
        self.ties = ties
        engines = sums.keys.sorted().map { key in
            let sum = sums[key]!
            return EngineSummary(
                engineKey: key,
                takes: sum.takes,
                meanOursWer: sum.oursWer / Double(sum.takes),
                meanOursMs: sum.oursMs / sum.takes,
                meanRivalWer: sum.rivalWer / Double(sum.takes),
                meanRivalMs: sum.rivalMs / sum.takes
            )
        }
    }
}
