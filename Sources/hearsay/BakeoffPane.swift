import AppKit
import Bakeoff
import SwiftUI

struct BakeoffPane: View {
    let coordinator: Coordinator
    @State private var fieldText = ""

    var body: some View {
        let summary = RunSummary(records: coordinator.bakeoff.records)
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(
                title: "Bake-off",
                subtitle: "Same audio, same key-up, one clock. Run Wispr Flow alongside. While this pane is front, dictations score instead of inserting — leave the pane and hearsay dictates normally."
            )

            HStack {
                Menu("Engine: \(coordinator.activeEngine.label)\(coordinator.activeEngine == coordinator.settings.engine ? "" : " (needs key)")") {
                    ForEach(Engine.all, id: \.wireKey) { engineOption in
                        Button(engineOption.label) { coordinator.select(engine: engineOption) }
                            .disabled(!engineOption.isAvailable)
                    }
                }
                .frame(width: 280)
                Spacer()
                Button("Retake last") { coordinator.bakeoff.deleteLast() }
                    .disabled(coordinator.bakeoff.records.isEmpty || !idle)
                Button("Archive & reset run") { coordinator.bakeoff.resetRun() }
                    .disabled(coordinator.bakeoff.records.isEmpty || !idle)
                Button("Delete all runs", role: .destructive) { coordinator.bakeoff.deleteAllRuns() }
                    .disabled((coordinator.bakeoff.records.isEmpty && coordinator.bakeoff.archivedRunCount == 0) || !idle)
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

            engineCards(summary)
            verdict(summary)
            rows(summary)
        }
        .onAppear { coordinator.bakeoffPaneVisible = true }
        .onDisappear { coordinator.bakeoffPaneVisible = false }
        .onChange(of: coordinator.bakeoff.records.count) { _, _ in
            fieldText = ""   // a take landed (or was retaken): the box is ready for the next sentence
        }
    }

    private var position: Int { coordinator.bakeoff.records.count }

    /// Run edits are only safe between sessions — a take in flight records into the run it started in.
    private var idle: Bool {
        switch coordinator.phase {
        case .idle, .settled: return true
        case .listening, .finishing: return false
        }
    }

    private var prompter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if position < BakeoffScript.sentences.count {
                let sentence = BakeoffScript.sentences[position]
                Text("sentence \(position + 1) of \(BakeoffScript.sentences.count) · \(sentence.language)")
                    .font(.caption).foregroundStyle(.secondary)
                if position > 0, BakeoffScript.sentences[position - 1].language != sentence.language, coordinator.activeEngine.needsLocale {
                    Label("switch hearsay language to \(Locale(identifier: sentence.language).languageDisplayName)", systemImage: "globe")
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

    private func engineCards(_ summary: RunSummary) -> some View {
        HStack(spacing: 12) {
            ForEach(summary.engines, id: \.engineKey) { engine in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\((Engine(wireKey: engine.engineKey)?.label ?? engine.engineKey).uppercased()) — \(engine.takes) scored")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                    Text("\(Self.percent(engine.meanOursWer)) · \(engine.meanOursMs) ms")
                        .font(.title3.bold()).foregroundStyle(.green)
                        + Text("  to text ready").font(.caption2).foregroundStyle(.secondary)
                    Text("wispr, same takes: \(Self.percent(engine.meanRivalWer)) · \(engine.meanRivalMs) ms")
                        .font(.caption).foregroundStyle(.orange)
                        + Text("  to text visible").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
            }
        }
    }

    @ViewBuilder
    private func verdict(_ summary: RunSummary) -> some View {
        if summary.decided >= 3 {
            Text(summary.wins >= summary.losses
                 ? "🏆 hearsay wins \(summary.wins) · wispr \(summary.losses)\(summary.ties > 0 ? " · ties \(summary.ties)" : "") — by WER only"
                 : "wispr leads \(summary.losses) · hearsay \(summary.wins)\(summary.ties > 0 ? " · ties \(summary.ties)" : "") — by WER only")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
        }
    }

    private func rows(_ summary: RunSummary) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(summary.takes.enumerated().reversed()), id: \.element.id) { index, take in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    Text(take.expected).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("\(Self.percent(take.oursWer)) · \(take.record.oursMs) ms").bold().foregroundStyle(.green)
                            if Engine(wireKey: take.record.engine) != .appleLocal {
                                Text("⚡\(take.record.engine.split(separator: "/").last.map(String.init) ?? take.record.engine)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        diffText(reference: take.expected, hypothesis: take.record.ours)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        if case .landed(let text, let ms) = take.record.rival, let rivalWer = take.rivalWer {
                            Text("\(Self.percent(rivalWer)) · \(ms) ms").bold().foregroundStyle(.orange)
                            diffText(reference: take.expected, hypothesis: text)
                        } else {
                            Text(take.record.rival.status).italic().foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 10)
                Divider()
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
    }

    private func diffText(reference: String, hypothesis: String) -> Text {
        Scorer.diff(reference: reference, hypothesis: hypothesis).reduce(Text("")) { partial, segment in
            partial + Text(segment.text)
                .foregroundColor(segment.verdict == .wrong ? .red : .secondary)
                .underline(segment.verdict == .wrong)
        }
        .font(.caption)
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
