public struct BakeoffSentence: Equatable, Sendable {
    public let text: String
    public let language: String
}

/// The read-aloud script for a comparison run. One sentence per fn+shift hold, in order.
public enum BakeoffScript {
    public static let sentences: [BakeoffSentence] = [
        .init(text: "Quick update before the demo: the migration finished last night, the staging database is back up, and the p95 latency is stable around 180ms. I still need to rewrite the onboarding email, chase the accountant about the August invoice, and confirm the venue for Thursday. If anything breaks with the OAuth flow, roll back to version 2.4.1 and ping me on Slack instead of email.", language: "en-US"),
        .init(text: "The deploy failed because the OAuth token expired, so CI rolled back to the previous release.", language: "en-US"),
        .init(text: "Ping me at dev@example.com when the Kubernetes cluster is back up.", language: "en-US"),
        .init(text: "The p99 latency spiked to 250ms after we enabled HTTP/2 on the load balancer.", language: "en-US"),
        .init(text: "Add a TODO to refactor the parseTranscript function before Thursday's demo.", language: "en-US"),
        .init(text: "Schedule the retro for 3pm CET and invite both the Lisbon and Stockholm teams.", language: "en-US"),
        .init(text: "I need three things: update the invoice, email the accountant, and book the flights.", language: "en-US"),
        .init(text: "The build takes 4 minutes and 30 seconds, down from 7 minutes.", language: "en-US"),
        .init(text: "Their deployment won't work there, and they're aware of it.", language: "en-US"),
        .init(text: "Merge the pull request from Alex and tag version 2.4.1.", language: "en-US"),
        .init(text: "The invoice totals €1,250 plus 23% VAT.", language: "en-US"),
        .init(text: "Let's use PostgreSQL instead of SQLite for the order database.", language: "en-US"),
        .init(text: "Honestly the overlay looks great, ship it.", language: "en-US"),
        .init(text: "Hej, kan du skicka fakturan för augusti senast på fredag?", language: "sv-SE"),
        .init(text: "Kan du pusha branchen till GitHub innan standupen imorgon?", language: "sv-SE"),
        .init(text: "Fakturan är på tolvtusen kronor exklusive moms.", language: "sv-SE"),
        .init(text: "Boka två biljetter till Lissabon den fjortonde september.", language: "sv-SE"),
        .init(text: "Olá, podes enviar a fatura de agosto até sexta-feira?", language: "pt-PT"),
        .init(text: "Marca dois bilhetes para Lisboa no dia catorze de setembro.", language: "pt-PT"),
    ]
}
