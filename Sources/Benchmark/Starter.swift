import Foundation

public enum BenchmarkStarter {
    public static func create(at directory: URL) throws {
        let files = FileManager.default
        let names = ["suite.json", "pipelines.json"]
        guard names.allSatisfy({ !files.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
            throw BenchmarkError("BenchmarkStarter.create: suite.json or pipelines.json already exists; choose a new folder")
        }
        try files.createDirectory(
            at: directory.appendingPathComponent("audio"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in names {
            guard let source = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw BenchmarkError("BenchmarkStarter.create: missing bundled template \(name)")
            }
            let target = directory.appendingPathComponent(name)
            try files.copyItem(at: source, to: target)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }
}
