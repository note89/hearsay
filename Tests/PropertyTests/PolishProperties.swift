import Foundation
import Testing

@testable import Polish

struct PolishProperties {
    @Test func canonicalUnicodeSpellingsHaveTheSameContent() {
        #expect(PolishGuard.contentWords("é ação") == PolishGuard.contentWords("e\u{301} ac\u{327}a\u{303}o"))
        if case .accept = PolishGuard.verdict(spoken: "é ação", candidate: "e\u{301} ac\u{327}a\u{303}o") {
        } else {
            Issue.record("Canonical spellings must preserve meaning")
        }
    }
    private func accepted(_ spoken: String, _ candidate: String) -> String? {
        if case .accept(let text) = PolishGuard.verdict(spoken: spoken, candidate: candidate) { return text.text }
        return nil
    }

    @Test func meaningfulIdentityAndWhitespaceTrimmingAreAccepted() {
        Properties.check(
            seed: 301, generate: { $0.words() },
            property: { words in
                let text = ("invoice " + words.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
                return accepted(text, text) == text
                    && accepted(text, "\n\t " + text + " \n") == text.trimmingCharacters(in: .whitespacesAndNewlines)
            })
    }

    @Test func fillerInsertionDoesNotChangeContentDecisions() {
        Properties.check(
            seed: 302, generate: { $0.words() },
            property: { words in
                let spoken = "invoice " + words.joined(separator: " ")
                return accepted(spoken, spoken) != nil && accepted("um uh " + spoken, spoken) != nil
            })
    }

    @Test func noContentCannotBypassTheGuard() {
        for (spoken, candidate) in [
            ("um uh", "Buy a new laptop tomorrow."),
            ("send the invoice by friday", "..."),
            ("send the invoice by friday", "um uh"),
        ] {
            guard case .keepRaw(.meaningDrift) = PolishGuard.verdict(spoken: spoken, candidate: candidate) else {
                Issue.record("guard accepted a content-free side: \(spoken) -> \(candidate)")
                continue
            }
        }
        guard case .keepRaw(.empty) = PolishGuard.verdict(spoken: "invoice", candidate: " \n\t") else {
            Issue.record("empty output must preserve raw text")
            return
        }
    }
}
