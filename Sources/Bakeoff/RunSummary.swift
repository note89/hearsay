import Foundation

public enum ScoredOutcome: Equatable {
    case scored(ours: String, ms: Int, wer: Double)
    case failed(reason: String)
}

public struct ScoredResult: Identifiable {
    public var id: String { engine }
    public let engine: String
    public let outcome: ScoredOutcome
}

public struct ScoredTake: Identifiable {
    public var id: String { take.id }
    public let take: Take
    public let expected: String
    public let results: [ScoredResult]
    /// nil when the rival's text never landed for this take.
    public let rivalWer: Double?
}

/// One engine over a run: its own numbers over every take it scored, and its record against the
/// rival over the takes both scored.
public struct EngineSummary: Identifiable {
    public var id: String { engineKey }
    public let engineKey: String
    public let scored: Int
    public let failed: Int
    public let meanOursWer: Double
    public let meanOursMs: Int
    public let wins: Int
    public let losses: Int
    public let ties: Int
    public let meanRivalWer: Double
    public let meanRivalMs: Int

    /// Takes both this engine and the rival scored.
    public var decided: Int { wins + losses + ties }
}

/// Scores a run: takes with an expected sentence, every engine's result in each, and a leaderboard.
/// Pure over takes, so it is testable without a view.
public struct RunSummary {
    public let takes: [ScoredTake]
    /// Every engine that appears in the run, best first: lower mean WER, then lower mean ms.
    /// Engines that scored nothing come last.
    public let leaderboard: [EngineSummary]

    public var leader: EngineSummary? { leaderboard.first { $0.scored > 0 } }

    private struct Tally {
        var scored = 0
        var failed = 0
        var oursWer = 0.0
        var oursMs = 0
        var wins = 0
        var losses = 0
        var ties = 0
        var rivalWer = 0.0
        var rivalMs = 0
    }

    public init(takes: [Take]) {
        var scoredTakes: [ScoredTake] = []
        var tallies: [String: Tally] = [:]
        var order: [String] = []
        for take in takes {
            guard let expected = take.expected else { continue }
            var rivalWer: Double?
            var rivalMs = 0
            if case .landed(let text, let ms) = take.rival {
                rivalWer = Scorer.wer(reference: expected, hypothesis: text)
                rivalMs = ms
            }
            var results: [ScoredResult] = []
            for result in take.results {
                if tallies[result.engine] == nil { order.append(result.engine) }
                var tally = tallies[result.engine] ?? Tally()
                switch result.outcome {
                case .scored(_, let ours, let ms):
                    let wer = Scorer.wer(reference: expected, hypothesis: ours)
                    tally.scored += 1
                    tally.oursWer += wer
                    tally.oursMs += ms
                    if let rivalWer {
                        tally.rivalWer += rivalWer
                        tally.rivalMs += rivalMs
                        if wer < rivalWer { tally.wins += 1 } else if rivalWer < wer { tally.losses += 1 } else { tally.ties += 1 }
                    }
                    results.append(ScoredResult(engine: result.engine, outcome: .scored(ours: ours, ms: ms, wer: wer)))
                case .failed(let reason):
                    tally.failed += 1
                    results.append(ScoredResult(engine: result.engine, outcome: .failed(reason: reason)))
                }
                tallies[result.engine] = tally
            }
            scoredTakes.append(ScoredTake(take: take, expected: expected, results: results, rivalWer: rivalWer))
        }
        self.takes = scoredTakes
        let summaries = order.map { key -> EngineSummary in
            let tally = tallies[key]!
            let decided = tally.wins + tally.losses + tally.ties
            return EngineSummary(
                engineKey: key,
                scored: tally.scored,
                failed: tally.failed,
                meanOursWer: tally.scored > 0 ? tally.oursWer / Double(tally.scored) : 1,
                meanOursMs: tally.scored > 0 ? tally.oursMs / tally.scored : 0,
                wins: tally.wins,
                losses: tally.losses,
                ties: tally.ties,
                meanRivalWer: decided > 0 ? tally.rivalWer / Double(decided) : 1,
                meanRivalMs: decided > 0 ? tally.rivalMs / decided : 0
            )
        }
        leaderboard = summaries.sorted { a, b in
            if (a.scored > 0) != (b.scored > 0) { return a.scored > 0 }
            if a.meanOursWer != b.meanOursWer { return a.meanOursWer < b.meanOursWer }
            return a.meanOursMs < b.meanOursMs
        }
    }
}
