import Foundation

/// One dictionary entry: a term to spell exactly, or a deterministic rewrite.
public enum LexiconEntry: Equatable, Hashable {
    case term(String)
    case rewrite(from: String, to: String)
}

/// The dictionary concept: get names and jargon right. Terms bias the on-device polish;
/// rewrites are applied deterministically after it. Entries are only ever added explicitly.
public struct Lexicon: Equatable {
    public let terms: [String]
    public let rewrites: [(from: String, to: String)]

    public static let empty = Lexicon(terms: [], rewrites: [])

    public static func == (lhs: Lexicon, rhs: Lexicon) -> Bool {
        lhs.terms == rhs.terms && lhs.rewrites.elementsEqual(rhs.rewrites, by: { $0.from == $1.from && $0.to == $1.to })
    }

    init(terms: [String], rewrites: [(from: String, to: String)]) {
        self.terms = terms
        self.rewrites = rewrites
    }

    public init(entries: [LexiconEntry]) {
        var terms: [String] = []
        var rewrites: [(from: String, to: String)] = []
        for entry in entries {
            switch entry {
            case .term(let term): terms.append(term)
            case .rewrite(let from, let to): rewrites.append((from: from, to: to))
            }
        }
        self.terms = terms
        self.rewrites = rewrites
    }

    public static func load(from url: URL) -> Lexicon {
        Lexicon(entries: entries(from: url))
    }

    /// The file's entries in order — the list the settings window edits.
    public static func entries(from url: URL) -> [LexiconEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries: [LexiconEntry] = []
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let arrow = line.range(of: "->") {
                let from = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                if !from.isEmpty && !to.isEmpty { entries.append(.rewrite(from: from, to: to)) }
            } else {
                entries.append(.term(line))
            }
        }
        return entries
    }

    /// Rewrites the file from the entry list (standard header; the file remains hand-editable).
    public static func save(_ entries: [LexiconEntry], to url: URL) {
        var content = fileHeader
        for entry in entries {
            switch entry {
            case .term(let term): content += term + "\n"
            case .rewrite(let from, let to): content += "\(from) -> \(to)\n"
            }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: url.path, contents: content.data(using: .utf8), attributes: [.posixPermissions: 0o600])
    }

    static let fileHeader = """
    # hearsay dictionary — one entry per line.
    #
    #   mprocs             a term: prefer this exact spelling when you say something close
    #   mprox -> mprocs    a rewrite: the left side always becomes the right side
    #
    # Lines starting with # are ignored. The dictionary is read fresh at every dictation.

    """

    /// Creates the dictionary file with a commented template when missing, so "Dictionary…" always opens something editable.
    @discardableResult
    public static func ensureFile(at url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: url.path, contents: fileHeader.data(using: .utf8), attributes: [.posixPermissions: 0o600])
        }
        return url
    }

    /// Applies the rewrites (case-insensitive, word-bounded). nil when nothing matched.
    public func rewriteResult(of text: String) -> String? {
        var result = text
        for rewrite in rewrites {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: rewrite.from) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: rewrite.to)
            )
        }
        return result == text ? nil : result
    }
}
