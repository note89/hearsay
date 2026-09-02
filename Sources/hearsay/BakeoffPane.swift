import AppKit
import Bakeoff
import SwiftUI

struct BakeoffPane: View {
    let coordinator: Coordinator
    @State private var fieldText = ""

    var body: some View {
        let summary = RunSummary(takes: coordinator.bakeoff.takes)
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(
                title: "Bake-off",
                subtitle: "Same audio, same key-up, one clock, every engine at once. Run Wispr Flow alongside. While this pane is front, dictations score instead of inserting. Engines are scored on their raw text — Style is a separate concept."
            )
            lineup
            HStack {
                Spacer()
                Button("Retake last") { coordinator.bakeoff.deleteLast() }
                    .disabled(coordinator.bakeoff.takes.isEmpty || !idle)
                Button("Archive & reset run") { coordinator.bakeoff.resetRun() }
                    .disabled(coordinator.bakeoff.takes.isEmpty || !idle)
                Button("Delete all runs", role: .destructive) { coordinator.bakeoff.deleteAllRuns() }
                    .disabled((coordinator.bakeoff.takes.isEmpty && coordinator.bakeoff.archivedRunCount == 0) || !idle)
            }

            prompter

            TextEditor(text: $fieldText)
                .font(.system(size: 15))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
                .overlay(alignment: .topLeading) {
                    if fieldText.isEmpty {
                        Text("click here, hold fn+shift, read the sentence, release")
                            .foregroundStyle(.secondary)
                            .padding(.top, 14).padding(.leading, 14)
                            .allowsHitTesting(false)
                    }
                }

            leaderboard(summary)
            verdict(summary)
            takes(summary)
        }
        .onAppear { coordinator.bakeoffPaneVisible = true }
        .onDisappear { coordinator.bakeoffPaneVisible = false }
        .onChange(of: coordinator.bakeoff.takes.count) { _, _ in
            fieldText = ""   // a take landed (or was retaken): the box is ready for the next sentence
        }
    }

    private var position: Int { coordinator.bakeoff.takes.count }

    /// Run edits are only safe between sessions — a take in flight records into the run it started in.
    private var idle: Bool {
        switch coordinator.phase {
        case .idle, .settled: return true
        case .listening, .finishing: return false
        }
    }

    /// Who races: a chip per engine. Engines without a key sit out; the lineup is a setting.
    private var lineup: some View {
        HStack(spacing: 8) {
            ForEach(Engine.all, id: \.wireKey) { engine in
                let racing = coordinator.settings.isRacing(engine) && engine.isAvailable
                Button { coordinator.settings.toggleRacing(engine) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: racing ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(racing ? Color.accentColor : Color.secondary)
                        Text(engine.shortLabel)
                        if !engine.isAvailable {
                            Text("needs key").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(racing ? Color.accentColor.opacity(0.16) : Color(nsColor: .quaternarySystemFill)))
                }
                .buttonStyle(.plain)
                .disabled(!engine.isAvailable || !idle)
            }
            Spacer()
        }
    }

    private var prompter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if position < BakeoffScript.sentences.count {
                let sentence = BakeoffScript.sentences[position]
                Text("sentence \(position + 1) of \(BakeoffScript.sentences.count) · \(sentence.language)")
                    .font(.caption).foregroundStyle(.secondary)
                if position > 0, BakeoffScript.sentences[position - 1].language != sentence.language, coordinator.settings.isRacing(.appleLocal) {
                    Label("Apple is locked to one language: switch it to \(Locale(identifier: sentence.language).languageDisplayName), or expect it to lose this one", systemImage: "globe")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(sentence.text)
                    .font(.system(size: 19, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("🏁 run complete — \(BakeoffScript.sentences.count) sentences")
                    .font(.system(size: 19, weight: .semibold))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .quaternarySystemFill)))
    }

    private func leaderboard(_ summary: RunSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(summary.leaderboard) { engine in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Self.name(engine.engineKey).uppercased()) — \(engine.scored) scored\(engine.failed > 0 ? " · \(engine.failed) failed" : "")")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                    if engine.scored > 0 {
                        Text("\(Self.percent(engine.meanOursWer)) · \(engine.meanOursMs) ms")
                            .font(.title3.bold()).foregroundStyle(.green)
                            + Text("  to text ready").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("no text yet").font(.title3.bold()).foregroundStyle(.secondary)
                    }
                    if engine.decided > 0 {
                        Text("vs wispr \(engine.wins)–\(engine.losses)\(engine.ties > 0 ? " (\(engine.ties) tied)" : "") · wispr \(Self.percent(engine.meanRivalWer)) · \(engine.meanRivalMs) ms")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
            }
        }
    }

    @ViewBuilder
    private func verdict(_ summary: RunSummary) -> some View {
        if let leader = summary.leader, leader.decided >= 3 {
            Text(leader.wins >= leader.losses
                 ? "🏆 \(Self.name(leader.engineKey)) leads at \(Self.percent(leader.meanOursWer)) · \(leader.meanOursMs) ms, and beats wispr \(leader.wins)–\(leader.losses) — by WER only"
                 : "\(Self.name(leader.engineKey)) leads our side at \(Self.percent(leader.meanOursWer)), but wispr wins \(leader.losses)–\(leader.wins) — by WER only")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
        }
    }

    private func takes(_ summary: RunSummary) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(summary.takes.enumerated().reversed()), id: \.element.id) { index, take in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        Text(take.expected).fontWeight(.medium)
                    }
                    ForEach(take.results) { result in
                        row(label: Self.name(result.engine), tint: .green) {
                            switch result.outcome {
                            case .scored(let ours, let ms, let wer):
                                Text("\(Self.percent(wer)) · \(ms) ms").bold().foregroundStyle(.green)
                                diffText(reference: take.expected, hypothesis: ours)
                            case .failed(let reason):
                                Text(reason).italic().foregroundStyle(.secondary)
                            }
                        }
                    }
                    row(label: "wispr", tint: .orange) {
                        if case .landed(let text, let ms) = take.take.rival, let rivalWer = take.rivalWer {
                            Text("\(Self.percent(rivalWer)) · \(ms) ms").bold().foregroundStyle(.orange)
                            diffText(reference: take.expected, hypothesis: text)
                        } else {
                            Text(take.take.rival.status).italic().foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
            }
        }
    }

    private func row<Content: View>(label: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(tint).frame(width: 96, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 22)
    }

    private func diffText(reference: String, hypothesis: String) -> Text {
        Scorer.diff(reference: reference, hypothesis: hypothesis).reduce(Text("")) { partial, segment in
            partial + Text(segment.text)
                .foregroundColor(segment.verdict == .wrong ? .red : .secondary)
                .underline(segment.verdict == .wrong)
        }
        .font(.caption)
    }

    private static func name(_ engineKey: String) -> String {
        Engine(wireKey: engineKey)?.shortLabel ?? engineKey
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
