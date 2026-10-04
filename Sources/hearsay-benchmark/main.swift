import AVFoundation
import Audio
import Benchmark
import Foundation
import Pipeline

@main
struct BenchmarkCommand {
    static func main() async {
        do { try await execute(Array(CommandLine.arguments.dropFirst())) } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static let usage = """
        usage:
          hearsay-benchmark init <corpus-directory>
          hearsay-benchmark record <corpus-directory> [case-id]
          hearsay-benchmark run <corpus-directory> [--all-models] [--execution sequential|parallel|hybrid] [--config <file>] [--output <report.json>] [--baseline <report.json>] [--fail-on-regression]
          hearsay-benchmark compare <baseline.json> <current.json> [--fail-on-regression]
          hearsay-benchmark engines
        """

    private static func execute(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            print(usage)
            return
        }
        if command == "--help" || command == "help" {
            print(usage)
            return
        }
        if command == "engines" {
            for engine in Engine.all { print("\(engine.wireKey)\t\(engine.shortLabel)") }
            return
        }
        guard arguments.count >= 2 else { throw BenchmarkError(usage) }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        switch command {
        case "init":
            guard arguments.count == 2 else { throw BenchmarkError(usage) }
            try BenchmarkStarter.create(at: directory)
            print("Created \(directory.path). Edit suite.json, then run record on this folder.")
        case "record":
            guard arguments.count <= 3 else { throw BenchmarkError(usage) }
            let suite = try BenchmarkSuite.load(at: directory)
            let cases = arguments.count == 3 ? suite.cases.filter { $0.id == arguments[2] } : suite.cases
            guard !cases.isEmpty else { throw BenchmarkError("BenchmarkCommand.record: unknown case ID") }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw BenchmarkError("BenchmarkCommand.record: allow microphone access for your terminal in System Settings")
            }
            for item in cases { try await record(item, directory: directory) }
            print("Recordings saved. Edit spoken to match what you actually said and expected to match the output you want.")
        case "run":
            let options = try parseOptions(Array(arguments.dropFirst(2)), paths: ["--config", "--output", "--baseline", "--execution"])
            let suite = try BenchmarkSuite.load(at: directory)
            let configURL = options["--config"].map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("pipelines.json")
            var config = try BenchmarkConfiguration.load(at: configURL)
            if options["--all-models"] != nil { config = config.includingAllModels() }
            if let mode = options["--execution"] {
                guard let execution = BenchmarkExecution(rawValue: mode) else {
                    throw BenchmarkError("BenchmarkCommand.run: unknown execution mode \(mode)")
                }
                config = config.selecting(execution: execution)
            }
            let baseline = try options["--baseline"].map { try BenchmarkReport.load(at: URL(fileURLWithPath: $0)) }
            if options["--fail-on-regression"] != nil, baseline == nil {
                throw BenchmarkError("BenchmarkCommand.run: --fail-on-regression requires --baseline")
            }
            let output =
                options["--output"].map { URL(fileURLWithPath: $0) }
                ?? directory.appendingPathComponent("runs/\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw BenchmarkError("BenchmarkCommand.run: output already exists; choose a new report path")
            }
            let cloud = config.pipelines.contains {
                $0.engine.privacyClass == .cloud || ($0.polish != .off && $0.polishEngine == .openRouter)
            }
            let ollama = config.pipelines.contains { $0.polish != .off && $0.polishEngine == .ollama }
            if cloud {
                print("Running configured cloud pipelines: audio/transcripts go to those providers.")
            } else {
                print(ollama ? "Running local speech pipelines with Ollama cleanup." : "Running on-device pipelines.")
            }
            if ollama {
                print("Ollama receives transcripts and dictionary terms. Local models stay local; Ollama cloud models use their provider.")
            }
            let report = try await BenchmarkRunner.run(
                suite: suite, directory: directory, configuration: config,
                codeRevision: ProcessInfo.processInfo.environment["HEARSAY_BENCHMARK_REVISION"] ?? "unknown",
                baseline: baseline,
                progress: { print($0) }
            )
            try report.save(to: output)
            let regressions: [String]?
            do { regressions = try baseline.map { try BenchmarkComparison.regressions(current: report, baseline: $0) } } catch {
                try saveMarkdown(BenchmarkRendering.markdown(report), beside: output)
                print("Saved \(output.path)")
                throw error
            }
            try saveMarkdown(BenchmarkRendering.markdown(report, regressions: regressions), beside: output)
            print(BenchmarkRendering.terminalSummary(report))
            print("Saved \(output.path) and \(output.deletingPathExtension().appendingPathExtension("md").path)")
            if let regressions { print(regressions.isEmpty ? "No quality regressions." : regressions.joined(separator: "\n")) }
            if report.measurements.contains(where: {
                if case .failed = $0.outcome { return true }
                return false
            }) {
                exit(1)
            }
            if options["--fail-on-regression"] != nil, regressions?.isEmpty == false { exit(1) }
        case "compare":
            guard arguments.count == 3 || (arguments.count == 4 && arguments[3] == "--fail-on-regression") else {
                throw BenchmarkError(usage)
            }
            let baseline = try BenchmarkReport.load(at: URL(fileURLWithPath: arguments[1]))
            let current = try BenchmarkReport.load(at: URL(fileURLWithPath: arguments[2]))
            let regressions = try BenchmarkComparison.regressions(current: current, baseline: baseline)
            print(BenchmarkRendering.terminalSummary(current))
            print(regressions.isEmpty ? "No quality regressions." : regressions.joined(separator: "\n"))
            if arguments.contains("--fail-on-regression"), !regressions.isEmpty { exit(1) }
        default: throw BenchmarkError(usage)
        }
    }

    private static func parseOptions(_ arguments: [String], paths: Set<String>) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard options[flag] == nil else { throw BenchmarkError("BenchmarkCommand: duplicate option \(flag)") }
            if flag == "--fail-on-regression" || flag == "--all-models" {
                options[flag] = "true"
                index += 1
            } else if paths.contains(flag), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                options[flag] = arguments[index + 1]
                index += 2
            } else {
                throw BenchmarkError("BenchmarkCommand: invalid option \(flag)\n\(usage)")
            }
        }
        return options
    }

    private static func saveMarkdown(_ text: String, beside output: URL) throws {
        let url = output.deletingPathExtension().appendingPathExtension("md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func record(_ item: BenchmarkCase, directory: URL) async throws {
        let target = directory.appendingPathComponent(item.audio)
        if FileManager.default.fileExists(atPath: target.path) {
            print("Skipping \(item.id): recording exists. Use a new case/audio path to preserve this take.")
            return
        }
        print("\n\(item.id) [\(item.locale)]\n\(item.spoken ?? item.expected)\n\nPress Return to record, then Return again to stop.")
        guard readLine() != nil else { throw BenchmarkError("BenchmarkCommand.record: standard input closed") }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).wav")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let capture = MicrophoneCapture()
        let stream = try capture.start { _ in }
        var captureStopped = false
        defer {
            if !captureStopped { capture.stop() }
            try? FileManager.default.removeItem(at: staging)
        }
        let writer = Task {
            var file: AVAudioFile?
            for await buffer in stream {
                if file == nil {
                    file = try AVAudioFile(forWriting: staging, settings: buffer.format.settings)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
                }
                try file?.write(from: buffer)
            }
            guard file != nil else { throw BenchmarkError("BenchmarkCommand.record: no audio captured") }
        }
        print("Recording…")
        let stopped = await Task.detached { readLine() != nil }.value
        capture.stop()
        captureStopped = true
        try await writer.value
        guard stopped else { throw BenchmarkError("BenchmarkCommand.record: input closed before stop") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: target)
        print("Saved \(target.path)")
    }
}
