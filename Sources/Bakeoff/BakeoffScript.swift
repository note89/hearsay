public struct BakeoffSentence: Equatable, Sendable {
    public let text: String
    public let language: String
}

/// The read-aloud script for a comparison run. One sentence per hold, in order. Ten sentences:
/// a long one, four with numbers and jargon, one Swedish, two svengelska, one Portuguese.
/// The Rust port carries the same list; keep them identical.
public enum BakeoffScript {
    public static let sentences: [BakeoffSentence] = [
        .init(text: "Quick update before the demo: the migration finished last night, the staging database is back up, and the p95 latency is stable around 180ms. I still need to rewrite the onboarding email, chase the accountant about the August invoice, and confirm the venue for Thursday. If anything breaks with the OAuth flow, roll back to version 2.4.1 and ping me on Slack instead of email.", language: "en-US"),
        .init(text: "The deploy failed because the OAuth token expired, so CI rolled back to the previous release.", language: "en-US"),
        .init(text: "The p99 latency spiked to 250ms after we enabled HTTP/2 on the load balancer.", language: "en-US"),
        .init(text: "Schedule the retro for 3pm CET and invite both the Lisbon and Stockholm teams.", language: "en-US"),
        .init(text: "The invoice totals €1,250 plus 23% VAT.", language: "en-US"),
        .init(text: "Merge the pull request from Alex and tag version 2.4.1.", language: "en-US"),
        .init(text: "Hej, kan du skicka fakturan för augusti senast på fredag?", language: "sv-SE"),
        .init(text: "Kan du merga branchen innan lunch? The CI is green now.", language: "sv-SE + en-US"),
        .init(text: "Vi deployar till staging ikväll, so don't push anything to main after 6pm.", language: "sv-SE + en-US"),
        .init(text: "Olá, podes enviar a fatura de agosto até sexta-feira?", language: "pt-PT"),
    ]
}
