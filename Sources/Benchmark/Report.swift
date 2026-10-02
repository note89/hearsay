import Foundation

public enum BenchmarkComparison {
    public static func checkCompatibility(
        fingerprint: String, configuration: BenchmarkConfiguration, baseline: BenchmarkReport
    ) throws {
        guard fingerprint == baseline.suiteFingerprint else {
            throw BenchmarkError("BenchmarkComparison: corpus or references changed; record a new baseline")
        }
        guard configuration.pacing == baseline.configuration.pacing,
            configuration.execution == baseline.configuration.execution,
            configuration.repetitions == baseline.configuration.repetitions,
            Set(configuration.pipelines.map(\.id)) == Set(baseline.configuration.pipelines.map(\.id))
        else {
            throw BenchmarkError("BenchmarkComparison: pacing, execution, repetitions and pipeline IDs must match")
        }
        try checkCoverage(baseline)
    }

    public static func regressions(current: BenchmarkReport, baseline: BenchmarkReport) throws -> [String] {
        try checkCompatibility(fingerprint: current.suiteFingerprint, configuration: current.configuration, baseline: baseline)
        try checkCoverage(current)
        var regressions: [String] = []
        for pipeline in current.configuration.pipelines {
            for item in current.suite.cases {
                let now = aggregate(current.measurements.filter { $0.pipelineID == pipeline.id && $0.caseID == item.id })
                let old = aggregate(baseline.measurements.filter { $0.pipelineID == pipeline.id && $0.caseID == item.id })
                var reasons: [String] = []
                if now.failed > old.failed { reasons.append("more failures") }
                if now.fallbacks > old.fallbacks { reasons.append("more cleanup fallbacks") }
                if !now.outputs.isEmpty, !old.outputs.isEmpty {
                    if now.wer > old.wer + 0.000001 { reasons.append("word errors increased") }
                    if now.cer > old.cer + 0.000001 { reasons.append("format/character errors increased") }
                }
                if now.exact < old.exact { reasons.append("fewer exact matches") }
                if !reasons.isEmpty { regressions.append("\(pipeline.id) / \(item.id): " + reasons.joined(separator: ", ")) }
            }
        }
        return regressions
    }

    private static func checkCoverage(_ report: BenchmarkReport) throws {
        guard (1...100).contains(report.configuration.repetitions), !report.suite.cases.isEmpty, !report.configuration.pipelines.isEmpty
        else {
            throw BenchmarkError("BenchmarkComparison: invalid report configuration")
        }
        let expected = Set(
            report.configuration.pipelines.flatMap { pipeline in
                report.suite.cases.flatMap { item in
                    (1...report.configuration.repetitions).map { "\(pipeline.id)/\(item.id)/\($0)" }
                }
            })
        let actual = report.measurements.map { "\($0.pipelineID)/\($0.caseID)/\($0.repetition)" }
        guard Set(actual) == expected, actual.count == expected.count else {
            throw BenchmarkError("BenchmarkComparison: incomplete or duplicate measurements")
        }
    }
}

public enum BenchmarkRendering {
    public static func markdown(_ report: BenchmarkReport, regressions: [String]? = nil) -> String {
        var text = "# \(report.suite.name)\n\n"
        text +=
            "Recorded \(report.createdAt.formatted(.iso8601)). Code: `\(report.codeRevision)`. Replay: **\(report.configuration.pacing.rawValue)**. Execution: **\(report.configuration.execution.rawValue)**.\n\n"
        text +=
            "Downloaded models run in a single lane because the inference runtime holds one model at a time. Hybrid runs cloud pipelines together, then local pipelines sequentially. Parallel overlaps that local lane with compatible Apple/cloud engines; timings include contention. Cold means weights were not resident in this process; the OS file cache may still be warm.\n\n"
        text += "Corpus fingerprint: `\(report.suiteFingerprint)`.\n\n"
        text +=
            "WER measures words and ignores punctuation; CER and exact matches retain case, punctuation and line breaks. Scores average completed takes; failures and cleanup fallbacks are counted separately. These are reference similarity measures, not a semantic quality judgment.\n\n"
        text +=
            "| Pipeline | Completed | Failed | Raw WER | Final WER | Final CER | Exact | Fallbacks | Cold model load | Total incl. setup p50 | Ready after audio p50 / p95 |\n"
        text += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
        for pipeline in report.configuration.pipelines {
            let rows = report.measurements.filter { $0.pipelineID == pipeline.id }
            let score = aggregate(rows)
            let raw = score.outputs.compactMap { $0.rawScore?.wer }
            let timing = score.outputs.map(\.finalAfterAudioMs).sorted()
            let ready = timing.isEmpty ? "—" : "\(percentile(timing, 0.5)) / \(percentile(timing, 0.95)) ms"
            let coldLoads = score.outputs.filter { $0.modelStartup == .cold }.map(\.modelLoadMs)
            let cold = coldLoads.isEmpty ? "—" : "\(percentile(coldLoads.sorted(), 0.5)) ms"
            let totals = score.outputs.map { $0.setupMs + $0.totalMs }.sorted()
            let total = totals.isEmpty ? "—" : "\(percentile(totals, 0.5)) ms"
            text +=
                "| \(pipeline.id) | \(score.outputs.count) / \(rows.count) | \(score.failed) | \(raw.isEmpty ? "—" : percent(mean(raw))) | \(score.outputs.isEmpty ? "—" : percent(score.wer)) | \(score.outputs.isEmpty ? "—" : percent(score.cer)) | \(score.exact) | \(score.fallbacks) | \(cold) | \(total) | \(ready) |\n"
        }
        if let regressions {
            text += "\n## Baseline comparison\n\n"
            text +=
                regressions.isEmpty ? "No quality regressions detected.\n" : regressions.map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        for item in report.suite.cases {
            text += "\n## \(item.id)\n\nExpected:\n\n\(codeBlock(item.expected))\n"
            if let wispr = item.wispr {
                let score = TextScore(reference: item.expected, hypothesis: wispr)
                text += "\nSaved Wispr Flow: WER \(percent(score.wer)), CER \(percent(score.characterErrorRate)).\n\n\(codeBlock(wispr))\n"
            }
            for row in report.measurements where row.caseID == item.id {
                text += "\n### \(row.pipelineID), repetition \(row.repetition)\n\n"
                switch row.outcome {
                case .failed(let reason, let totalMs): text += "Failed after \(totalMs) ms:\n\n\(codeBlock(reason))\n"
                case .completed(let output):
                    text +=
                        "WER \(percent(output.finalScore.wer)), CER \(percent(output.finalScore.characterErrorRate)); transcription tail \(output.afterAudioMs) ms, cleanup \(output.polishMs) ms, ready \(output.finalAfterAudioMs) ms after audio. Setup \(output.setupMs) ms excluded.\n\n"
                    text +=
                        "Model: \(output.modelStartup.rawValue), load \(output.modelLoadMs) ms. Total including setup: \(output.setupMs + output.totalMs) ms.\n\n"
                    if let reason = output.cleanupRejection { text += "Cleanup kept raw: `\(reason)`.\n\n" }
                    text += "Raw:\n\n\(codeBlock(output.raw))\n\nDelivered:\n\n\(codeBlock(output.delivered))\n"
                }
            }
        }
        return text
    }

    public static func terminalSummary(_ report: BenchmarkReport) -> String {
        report.configuration.pipelines.map { pipeline in
            let score = aggregate(report.measurements.filter { $0.pipelineID == pipeline.id })
            return
                "\(pipeline.id): \(score.outputs.count) completed, \(score.failed) failed, WER \(score.outputs.isEmpty ? "—" : percent(score.wer)), CER \(score.outputs.isEmpty ? "—" : percent(score.cer)), \(score.fallbacks) cleanup fallbacks"
        }.joined(separator: "\n")
    }
}

private struct Aggregate {
    let outputs: [BenchmarkOutput]
    let failed: Int
    var fallbacks: Int { outputs.filter { $0.cleanupRejection != nil }.count }
    var wer: Double { mean(outputs.map { $0.finalScore.wer }) }
    var cer: Double { mean(outputs.map { $0.finalScore.characterErrorRate }) }
    var exact: Int { outputs.filter { $0.finalScore.exact }.count }
}

private func aggregate(_ rows: [BenchmarkMeasurement]) -> Aggregate {
    let outputs = rows.compactMap { row -> BenchmarkOutput? in
        if case .completed(let output) = row.outcome { return output }
        return nil
    }
    return Aggregate(outputs: outputs, failed: rows.count - outputs.count)
}

private func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
private func percentile(_ sorted: [Int], _ fraction: Double) -> Int { sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
private func codeBlock(_ text: String) -> String {
    let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
    let fence = String(repeating: "`", count: max(3, longest + 1))
    return "\(fence)text\n\(text)\n\(fence)"
}
