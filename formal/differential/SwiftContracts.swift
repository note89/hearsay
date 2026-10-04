import Foundation

struct ContractRule: Decodable {
    let from: String
    let to: String
}

struct ContractCase: Decodable {
    let reference: String
    let hypothesis: String
    let rewrites: [ContractRule]
}

struct ContractSegment: Encodable {
    let text: String
    let wrong: Bool
}

struct ContractResult: Encodable {
    let referenceTokens: [String]
    let hypothesisTokens: [String]
    let distance: Int
    let wer: Double
    let diff: [ContractSegment]
    let rewrite: String?
    let polish: String
}

@main
struct SwiftContracts {
    static func main() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        while let line = readLine() {
            let input = try decoder.decode(ContractCase.self, from: Data(line.utf8))
            let reference = Scorer.normalize(input.reference)
            let hypothesis = Scorer.normalize(input.hypothesis)
            let dictionary = Lexicon(entries: input.rewrites.map { .rewrite(from: $0.from, to: $0.to) })
            let polish: String
            switch PolishGuard.verdict(spoken: input.reference, candidate: input.hypothesis) {
            case .accept(let text): polish = "accept:" + text.text
            case .keepRaw(let reason): polish = "reject:" + reason.label
            }
            let result = ContractResult(
                referenceTokens: reference, hypothesisTokens: hypothesis,
                distance: Scorer.editDistance(reference, hypothesis),
                wer: Scorer.wer(reference: input.reference, hypothesis: input.hypothesis),
                diff: Scorer.diff(reference: input.reference, hypothesis: input.hypothesis).map {
                    ContractSegment(text: $0.text, wrong: $0.verdict == .wrong)
                },
                rewrite: dictionary.rewriteResult(of: input.hypothesis), polish: polish)
            // Encode nil explicitly: both drivers expose the same JSON contract.
            var json = try JSONSerialization.jsonObject(with: encoder.encode(result)) as! [String: Any]
            if result.rewrite == nil { json["rewrite"] = NSNull() }
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
