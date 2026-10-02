import Foundation
import Testing

@testable import Transcription

struct LocalSpeechModelTests {
    @Test func whisperMapsCanonicalLocalesToItsLanguageTokens() {
        #expect(LocalSpeechModel.whisper.languageCode(for: Locale(identifier: "jv-ID")) == "jw")
        #expect(LocalSpeechModel.whisper.languageCode(for: Locale(identifier: "jw")) == "jw")
        #expect(LocalSpeechModel.whisper.languageCode(for: Locale(identifier: "nb-NO")) == "no")
        #expect(LocalSpeechModel.whisper.languageCode(for: Locale(identifier: "no")) == "no")
        #expect(LocalSpeechModel.whisper.languageCode(for: Locale(identifier: "fil_PH")) == "tl")
        #expect(LocalSpeechModel.whisper.languageCode(for: Locale(identifier: "tl_PH")) == "tl")
        #expect(LocalSpeechModel.whisper.languageCode(for: Locale(identifier: "nn-NO")) == "nn")
        #expect(LocalSpeechModel.whisper.languageCode(for: Locale(identifier: "sv-SE")) == "sv")
    }

    @Test func cohereRejectsSwedishAndKeepsSupportedRegionalLanguages() {
        #expect(LocalSpeechModel.cohere.needsLocale)
        #expect(LocalSpeechModel.cohere.languageCode(for: Locale(identifier: "sv-SE")) == nil)
        #expect(LocalSpeechModel.cohere.languageCode(for: Locale(identifier: "nb-NO")) == nil)
        #expect(LocalSpeechModel.cohere.languageCode(for: Locale(identifier: "pt-PT")) == "pt")
    }

    @Test func automaticModelsDoNotForceTheSelectedLocale() {
        for model in [LocalSpeechModel.qwen, .redux] {
            #expect(!model.needsLocale)
            #expect(model.languageCode(for: Locale(identifier: "sv-SE")) == nil)
            #expect(model.languageCodes.isEmpty)
            #expect(model.supportedLanguageCodes.contains("sv"))
            #expect(model.supportedLanguageCodes.contains("pt"))
        }
    }

    @Test func publishedLanguageCoverageIsCompleteAndUnique() {
        let publishedCounts: [LocalSpeechModel: Int] = [.cohere: 14, .qwen: 30, .redux: 25, .whisper: 100]
        for model in LocalSpeechModel.allCases {
            #expect(model.supportedLanguageCodes.count == publishedCounts[model])
            #expect(Set(model.supportedLanguageCodes).count == model.supportedLanguageCodes.count)
            if model.needsLocale { #expect(model.languageCodes == model.supportedLanguageCodes) }
        }
        #expect(LocalSpeechModel.qwen.supportedLanguageCodes.contains("fil"))
        #expect(LocalSpeechModel.qwen.supportedLanguageCodes.contains("yue"))
        #expect(!LocalSpeechModel.cohere.supportedLanguageCodes.contains("sv"))
        #expect(!LocalSpeechModel.redux.supportedLanguageCodes.contains("zh"))
    }
}
