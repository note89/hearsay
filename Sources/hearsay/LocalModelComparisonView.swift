import Foundation
import SwiftUI
import Transcription

struct LocalModelComparisonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare local models").font(.headline)
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Model")
                        Text("Download")
                        Text("Loading + first\ntranscription")
                        Text("Repeat dictation\n(model loaded)")
                        Text("Languages")
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(LocalSpeechModel.allCases, id: \.self) { model in
                        GridRow(alignment: .top) {
                            Text(model.label)
                            Text(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file))
                            Text(LocalModelComparison.firstRun(for: model)).monospacedDigit()
                            Text("Not measured yet").foregroundStyle(.secondary)
                            DisclosureGroup("\(model.supportedLanguageCodes.count) languages") {
                                Text(
                                    model.supportedLanguageCodes.map(SpeechLanguagePresentation.init).map(\.label).joined(separator: " · ")
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                            }
                            .frame(width: 180, alignment: .leading)
                        }
                        .font(.caption)
                    }
                }
                .padding(.bottom, 4)
            }
            Text(
                "Loading happens when you activate a model. Hearsay keeps it in memory for the next dictations; it loads again after switching engines or restarting Hearsay."
            )
            .font(.caption)
            Text(
                "Initial measurements: M3 Pro with 18 GB memory, same short English recording, development build. Times include loading and recognition, excluding cleanup. Accuracy and repeat-dictation speed have not been ranked. Use Bake-off to compare recordings of your own voice."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
    }
}

enum LocalModelComparison {
    static func firstRun(for model: LocalSpeechModel) -> String {
        switch model {
        case .cohere: return "5.28 s"
        case .qwen: return "6.43 s"
        case .redux: return "5.31 s"
        case .whisper: return "7.09 s"
        }
    }

    static func guidance(for model: LocalSpeechModel) -> String {
        switch model {
        case .cohere: return "Try for English or Portuguese. Swedish is not supported."
        case .qwen: return "A starting point for English, Swedish and Portuguese, with automatic language detection."
        case .redux: return "The smallest download. Compare its accuracy and speed on your own recordings."
        case .whisper: return "Broad language coverage. Choose the spoken language before dictating."
        }
    }
}

struct LocalModelLanguagesView: View {
    let model: LocalSpeechModel

    private var languages: [SpeechLanguagePresentation] {
        model.supportedLanguageCodes.map(SpeechLanguagePresentation.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var preview: String {
        ["en", "sv", "pt"].compactMap { code in
            languages.first { $0.canonicalCode == code }?.label
        }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalModelComparison.guidance(for: model)).font(.caption)
            Text(preview).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("All \(languages.count) supported languages") {
                Text(languages.map(\.label).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                Text("Flags are visual cues; support is not restricted to those countries.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                if model == .qwen {
                    Text("Qwen also lists support for 22 Chinese dialects.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption)
            Link("Model information", destination: URL(string: "https://huggingface.co/\(model.repositoryID)")!)
                .font(.caption)
        }
    }
}

/// Language names remain readable when flag emoji are unavailable or ambiguous.
struct SpeechLanguagePresentation {
    let code: String

    init(_ code: String) { self.code = code }

    var canonicalCode: String {
        Locale(identifier: code).language.languageCode?.identifier ?? code
    }

    var name: String {
        Locale.current.localizedString(forLanguageCode: canonicalCode)
            ?? Locale(identifier: "en").localizedString(forLanguageCode: canonicalCode)
            ?? canonicalCode
    }

    var flag: String {
        let regions: [String]
        switch canonicalCode {
        case "en": regions = ["GB", "US"]
        case "pt": regions = ["PT", "BR"]
        default:
            let locale = Locale(identifier: Locale.Language(identifier: canonicalCode).maximalIdentifier)
            regions = locale.region.map { [$0.identifier] } ?? []
        }
        let flags = regions.compactMap { region -> String? in
            let scalars = Array(region.uppercased().unicodeScalars)
            guard scalars.count == 2, scalars.allSatisfy({ (65...90).contains($0.value) }) else { return nil }
            return String(String.UnicodeScalarView(scalars.map { UnicodeScalar(127_397 + $0.value)! }))
        }
        return flags.isEmpty ? "🌐" : flags.joined()
    }

    var label: String { "\(flag) \(name)" }
}
