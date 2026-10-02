import Pipeline

public enum BenchmarkExecution: String, Codable, Sendable {
    case sequential, parallel, hybrid
}

/// Downloaded engines share one resident model in the inference runtime. Keep a whole pipeline
/// in one lane so another model cannot replace its weights between preparation and transcription.
public enum BenchmarkScheduler {
    public static func run<T: Sendable>(
        _ pipelines: [BenchmarkPipeline], execution: BenchmarkExecution,
        work: @escaping @Sendable (BenchmarkPipeline) async -> T
    ) async -> [T] {
        if execution == .sequential {
            var results: [T] = []
            for pipeline in pipelines { results.append(await work(pipeline)) }
            return results
        }
        let serial = pipelines.filter { pipeline in
            if execution == .hybrid { return pipeline.engine.privacyClass == .onDevice }
            if case .local = pipeline.engine { return true }
            return false
        }
        let concurrent = pipelines.filter { pipeline in !serial.contains(where: { $0.id == pipeline.id }) }
        var results: [String: T] = [:]
        await withTaskGroup(of: [(String, T)].self) { group in
            for pipeline in concurrent {
                group.addTask { [(pipeline.id, await work(pipeline))] }
            }
            if execution == .parallel {
                group.addTask {
                    var local: [(String, T)] = []
                    for pipeline in serial { local.append((pipeline.id, await work(pipeline))) }
                    return local
                }
            }
            for await rows in group { for (id, result) in rows { results[id] = result } }
        }
        if execution == .hybrid {
            for pipeline in serial { results[pipeline.id] = await work(pipeline) }
        }
        return pipelines.compactMap { results[$0.id] }
    }
}
