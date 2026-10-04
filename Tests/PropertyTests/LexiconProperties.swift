import Foundation
import Lexicon
import Testing

struct LexiconProperties {
    private func rewrite(_ dictionary: Lexicon, _ text: String) -> String {
        dictionary.rewriteResult(of: text) ?? text
    }

    @Test func emptyDictionaryIsIdentity() {
        Properties.check(
            seed: 201, generate: { $0.words() },
            property: { words in
                Lexicon.empty.rewriteResult(of: words.joined(separator: " ")) == nil
            })
    }

    @Test func independentRewriteRulesCommuteAndAreIdempotent() {
        let first = LexiconEntry.rewrite(from: "mprox", to: "mprocs")
        let second = LexiconEntry.rewrite(from: "key cloak", to: "Keycloak")
        let forward = Lexicon(entries: [first, second])
        let reverse = Lexicon(entries: [second, first])
        Properties.check(
            seed: 202,
            generate: { random in
                let words = ["Mprox", "key cloak", "invoice", "amprox", "key cloaks", "Keycloak"]
                return (0..<random.integer(0..<16)).map { _ in words[random.integer(words.indices)] }
            },
            property: { words in
                let text = words.joined(separator: " ")
                let result = rewrite(forward, text)
                return result == rewrite(reverse, text) && rewrite(forward, result) == result
            })
    }

    @Test func chainedRulesAreOrderedRatherThanCommutative() {
        let ab = LexiconEntry.rewrite(from: "a", to: "b")
        let bc = LexiconEntry.rewrite(from: "b", to: "c")
        #expect(rewrite(Lexicon(entries: [ab, bc]), "a") == "c")
        let reverse = Lexicon(entries: [bc, ab])
        #expect(rewrite(reverse, "a") == "b")
        #expect(rewrite(reverse, rewrite(reverse, "a")) == "c")
    }

    @Test func replacementsAreLiteralAndRegexMetacharactersAreEscaped() {
        let dictionary = Lexicon(entries: [.rewrite(from: "a.b", to: "$1\\name")])
        #expect(rewrite(dictionary, "a.b axb za.b a.bz") == "$1\\name axb za.b a.bz")
        #expect(Lexicon(entries: [.rewrite(from: "invoice", to: "invoice")]).rewriteResult(of: "invoice") == nil)
    }

    @Test func representableEntriesRoundTripThroughDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("dictionary.txt")
        Properties.check(
            seed: 203, cases: 80,
            generate: { random in
                (0..<random.integer(0..<15)).map { _ in
                    let word = "term\(random.integer(0..<10000))"
                    return random.integer(0..<2) == 0 ? LexiconEntry.term(word) : .rewrite(from: word, to: "canonical\(word)")
                }
            },
            property: { entries in
                Lexicon.save(entries, to: file)
                return Lexicon.entries(from: file) == entries
            })
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
