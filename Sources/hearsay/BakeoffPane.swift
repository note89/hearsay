import AppKit
import Bakeoff
import SwiftUI

struct BakeoffPane: View {
    let coordinator: Coordinator
    @State private var arenaText = ""
    @State private var lastCount = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeaderShared(
                title: "Bake-off",
                subtitle: "Same audio, same key-up, one clock. Run Wispr Flow alongside. While this pane is front, dictations score instead of inserting — leave the pane and hearsay dictates normally."
            )

            HStack {
                Menu("Engine: \(coordinator.settings.engine.label)") {
                    ForEach(Engine.all, id: \.wireKey) { engineOption in
                        Button(engineOption.label) { coordinator.select(engine: engineOption) }
                            .disabled(!engineOption.isAvailable)
                    }
                }
                .frame(width: 280)
                Spacer()
                Button("Reset run", role: .destructive) { coordinator.bakeoff.resetRun() }
                    .disabled(coordinator.bakeoff.records.isEmpty)
            }

            prompter

            TextEditor(text: $arenaText)
                .font(.system(size: 15))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
                .overlay(alignment: .topLeading) {
                    if arenaText.isEmpty {
                        Text("click here, hold fn+shift, read the sentence, release")
                            .foregroundStyle(.secondary)
                            .padding(.top, 14).padding(.leading, 14)
                            .allowsHitTesting(false)
                    }
                }

            summary
            verdictLine
            resultRows
        }
        .onAppear { coordinator.bakeoffPaneVisible = true }
        .onDisappear { coordinator.bakeoffPaneVisible = false }
        .onChange(of: coordinator.bakeoff.records.count) { _, newCount in
            if newCount != lastCount {
                arenaText = ""
                lastCount = newCount
            }
        }
    }

    private var position: Int { coordinator.bakeoff.records.count }

    private var prompter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if position < BakeoffScript.sentences.count {
                let sentence = BakeoffScript.sentences[position]
                Text("sentence \(position + 1) of \(BakeoffScript.sentences.count) · \(sentence.language)")
                    .font(.caption).foregroundStyle(.secondary)
                if position > 0, BakeoffScript.sentences[position - 1].language != sentence.language, coordinator.settings.engine.needsLocale {
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

    private struct EngineGroup {
        var count = 0
        var oursWer = 0.0
        var oursMs = 0
        var rivalWer = 0.0
        var rivalMs = 0
    }

    private var scored: [(record: BakeoffRecord, expected: String, oursWer: Double, rivalWer: Double?)] {
        coordinator.bakeoff.records.compactMap { record in
            guard let expected = record.expected else { return nil }
            let ours = Scorer.wer(reference: expected, hypothesis: record.ours)
            let rival: Double?
            if record.rivalStatus == .landed, let rivalText = record.rival {
                rival = Scorer.wer(reference: expected, hypothesis: rivalText)
            } else {
                rival = nil
            }
            return (record, expected, ours, rival)
        }
    }

    private var summary: some View {
        var groups: [String: EngineGroup] = [:]
        for row in scored where row.rivalWer != nil {
            var group = groups[row.record.engine, default: EngineGroup()]
            group.count += 1
            group.oursWer += row.oursWer
            group.oursMs += row.record.oursMs
            group.rivalWer += row.rivalWer ?? 0
            group.rivalMs += row.record.rivalMs ?? 0
            groups[row.record.engine] = group
        }
        return HStack(spacing: 12) {
            ForEach(groups.sorted(by: { $0.key < $1.key }), id: \.key) { key, group in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\((Engine(wireKey: key)?.label ?? key).uppercased()) — \(group.count) scored")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                    Text("\(Self.percent(group.oursWer / Double(group.count))) · \(group.oursMs / group.count) ms")
                        .font(.title3.bold()).foregroundStyle(.green)
                        + Text("  to text ready").font(.caption2).foregroundStyle(.secondary)
                    Text("wispr, same rows: \(Self.percent(group.rivalWer / Double(group.count))) · \(group.rivalMs / group.count) ms")
                        .font(.caption).foregroundStyle(.orange)
                        + Text("  to text visible").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
            }
        }
    }

    @ViewBuilder
    private var verdictLine: some View {
        let decided = scored.filter { $0.rivalWer != nil }
        let wins = decided.filter { $0.oursWer < ($0.rivalWer ?? 1) }.count
        let losses = decided.filter { ($0.rivalWer ?? 1) < $0.oursWer }.count
        let ties = decided.count - wins - losses
        if decided.count >= 3 {
            Text(wins >= losses
                 ? "🏆 hearsay wins \(wins) · wispr \(losses)\(ties > 0 ? " · ties \(ties)" : "") — by WER only"
                 : "wispr leads \(losses) · hearsay \(wins)\(ties > 0 ? " · ties \(ties)" : "") — by WER only")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
        }
    }

    private var resultRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(scored.enumerated().reversed()), id: \.element.record.id) { index, row in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    Text(row.expected).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("\(Self.percent(row.oursWer)) · \(row.record.oursMs) ms").bold().foregroundStyle(.green)
                            if row.record.engine != "apple-local" {
                                Text("⚡\(row.record.engine.split(separator: "/").last.map(String.init) ?? row.record.engine)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        diffText(reference: row.expected, hypothesis: row.record.ours)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        if let rivalWer = row.rivalWer, let rivalText = row.record.rival {
                            Text("\(Self.percent(rivalWer)) · \(row.record.rivalMs ?? 0) ms").bold().foregroundStyle(.orange)
                            diffText(reference: row.expected, hypothesis: rivalText)
                        } else {
                            Text(row.record.rivalStatus.rawValue).italic().foregroundStyle(.secondary)
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
