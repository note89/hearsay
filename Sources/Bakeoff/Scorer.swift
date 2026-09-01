import Foundation

public enum DiffVerdict: Equatable {
    case match
    case wrong
}

public struct DiffSegment: Equatable {
    public let text: String
    public let verdict: DiffVerdict
}

/// Word error rate and word-level diff over normalized tokens: numeral style ("700" vs "seven hundred"),
/// ordinals, units ("5ms"), contractions, and letter/digit boundaries ("HTTP2") never count as errors.
public enum Scorer {
    public static func wer(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(editDistance(ref, hyp)) / Double(ref.count)
    }

    /// The hypothesis split into whitespace-preserving segments, wrong words marked.
    public static func diff(reference: String, hypothesis: String) -> [DiffSegment] {
        let refN = normalize(reference)
        var hypN: [String] = []
        var sourceIndex: [Int] = []
        let parts = chunks(of: hypothesis)
        for (index, part) in parts.enumerated() where !part.allSatisfy(\.isWhitespace) {
            for token in normalizeToken(part.lowercased()) {
                hypN.append(token)
                sourceIndex.append(index)
            }
        }
        let bad = badHypothesisTokens(ref: refN, hyp: hypN, sourceIndex: sourceIndex)
        return parts.enumerated().map { index, part in
            DiffSegment(text: part, verdict: bad.contains(index) ? .wrong : .match)
        }
    }

    // MARK: - Normalization

    static func normalize(_ text: String) -> [String] {
        var t = text.lowercased()
        t = regexReplace(t, pattern: #"(\d),(?=\d)"#, template: "$1")
        t = t.replacingOccurrences(of: "%", with: " percent ")
        t = regexReplace(t, pattern: #"[^\p{L}\p{N}\s']"#, template: " ")
        return t.split(whereSeparator: \.isWhitespace).flatMap { normalizeToken(String($0)) }
    }

    static func normalizeToken(_ raw: String) -> [String] {
        var token = raw.lowercased()
        token = regexReplace(token, pattern: #"(\d),(?=\d)"#, template: "$1")
        token = regexReplace(token, pattern: #"[^\p{L}\p{N}\s']"#, template: " ")
        let pieces = token.split(whereSeparator: \.isWhitespace).map(String.init)
        if pieces.count != 1 { return pieces.flatMap { normalizeToken($0) } }
        let t = pieces[0]
        if let expansion = Self.contractions[t] { return expansion.split(separator: " ").map(String.init) }
        if t.allSatisfy(\.isNumber), let n = Int(t) { return numberWords(n).split(separator: " ").map(String.init) }
        if let match = firstMatch(t, pattern: #"^(\d+)(st|nd|rd|th)$"#), let n = Int(match[1]) {
            return ordinalWords(n).split(separator: " ").map(String.init)
        }
        if let match = firstMatch(t, pattern: #"^(\d+)([a-z]+)$"#), let unit = Self.units[match[2]], let n = Int(match[1]) {
            return numberWords(n).split(separator: " ").map(String.init) + [unit]
        }
        if let unit = Self.units[t] { return [unit] }
        if t.contains(where: \.isLetter) && t.contains(where: \.isNumber) {
            return splitLetterDigitBoundaries(t).flatMap { normalizeToken($0) }
        }
        return [t]
    }

    static func numberWords(_ n: Int) -> String {
        if n < 0 || n >= 1000 { return String(n) }
        if n <= 20 { return Self.ones[n] }
        if n < 100 {
            let tens = Self.tens[n / 10] ?? String(n / 10)
            let rest = n % 10
            return rest == 0 ? tens : "\(tens) \(Self.ones[rest])"
        }
        let hundreds = "\(Self.ones[n / 100]) hundred"
        let rest = n % 100
        return rest == 0 ? hundreds : "\(hundreds) \(numberWords(rest))"
    }

    static func ordinalWords(_ n: Int) -> String {
        var words = numberWords(n).split(separator: " ").map(String.init)
        guard let last = words.popLast() else { return String(n) }
        let ordinal: String
        if let special = Self.ordinals[last] {
            ordinal = special
        } else if last.hasSuffix("y") {
            ordinal = String(last.dropLast()) + "ieth"
        } else {
            ordinal = last + "th"
        }
        return (words + [ordinal]).joined(separator: " ")
    }

    // MARK: - Alignment

    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            if b.isEmpty { current = [i] }
            previous = current
        }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        return previous[b.count]
    }

    private static func badHypothesisTokens(ref: [String], hyp: [String], sourceIndex: [Int]) -> Set<Int> {
        let n = ref.count, m = hyp.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    dp[i][j] = min(dp[i-1][j] + 1, dp[i][j-1] + 1, dp[i-1][j-1] + (ref[i-1] == hyp[j-1] ? 0 : 1))
                }
            }
        }
        var bad = Set<Int>()
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && dp[i][j] == dp[i-1][j-1] + (ref[i-1] == hyp[j-1] ? 0 : 1) {
                if ref[i-1] != hyp[j-1] { bad.insert(sourceIndex[j-1]) }
                i -= 1; j -= 1
            } else if j > 0 && dp[i][j] == dp[i][j-1] + 1 {
                bad.insert(sourceIndex[j-1]); j -= 1
            } else {
                i -= 1
            }
        }
        return bad
    }

    // MARK: - Helpers & tables

    private static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for character in text {
            let isSpace = character.isWhitespace
            if currentIsSpace == nil || currentIsSpace == isSpace {
                current.append(character)
            } else {
                result.append(current)
                current = String(character)
            }
            currentIsSpace = isSpace
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func splitLetterDigitBoundaries(_ token: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var lastIsDigit: Bool?
        for character in token {
            let isDigit = character.isNumber
            if lastIsDigit == nil || lastIsDigit == isDigit || (!character.isLetter && !character.isNumber) {
                current.append(character)
            } else {
                parts.append(current)
                current = String(character)
            }
            lastIsDigit = isDigit
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func regexReplace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func firstMatch(_ text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }

    private static let ones = ["zero","one","two","three","four","five","six","seven","eight","nine","ten","eleven","twelve","thirteen","fourteen","fifteen","sixteen","seventeen","eighteen","nineteen","twenty"]
    private static let tens = [2:"twenty",3:"thirty",4:"forty",5:"fifty",6:"sixty",7:"seventy",8:"eighty",9:"ninety"]
    private static let ordinals = ["one":"first","two":"second","three":"third","five":"fifth","eight":"eighth","nine":"ninth","twelve":"twelfth","twenty":"twentieth"]
    private static let units = ["ms":"milliseconds","s":"seconds","min":"minutes","h":"hours","km":"kilometers","kg":"kilograms","gb":"gigabytes","mb":"megabytes","kb":"kilobytes","hz":"hertz","khz":"kilohertz","mhz":"megahertz","ghz":"gigahertz","pm":"pm","am":"am"]
    private static let contractions = ["won't":"will not","can't":"can not","don't":"do not","doesn't":"does not","didn't":"did not","isn't":"is not","aren't":"are not","wasn't":"was not","weren't":"were not","haven't":"have not","hasn't":"has not","hadn't":"had not","wouldn't":"would not","shouldn't":"should not","couldn't":"could not","i'm":"i am","i've":"i have","i'll":"i will","i'd":"i would","you're":"you are","you've":"you have","you'll":"you will","they're":"they are","they've":"they have","they'll":"they will","we're":"we are","we've":"we have","we'll":"we will","it's":"it is","that's":"that is","there's":"there is","let's":"let us","what's":"what is","who's":"who is","he's":"he is","she's":"she is","here's":"here is"]
}
