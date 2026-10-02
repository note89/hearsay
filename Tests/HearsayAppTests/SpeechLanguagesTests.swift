import Foundation
import Testing
import Transcription

@testable import hearsay

struct SpeechLanguagesTests {
    private let appleLocales = ["en-GB", "en-US", "pt-BR", "pt-PT", "sv-SE"].map(Locale.init(identifier:))

    @Test func coherePreservesExactAppleLocalesForEnglishAndPortuguese() throws {
        let choices = SpeechLanguages.choices(for: .cohere, availableLocales: appleLocales, userRegion: nil)
        let english = try #require(choices.first { $0.language.languageCode?.identifier == "en" })
        let portuguese = try #require(choices.first { $0.language.languageCode?.identifier == "pt" })
        #expect(appleLocales.contains(english))
        #expect(appleLocales.contains(portuguese))
        #expect(english.identifier(.bcp47) == "en-US")
        #expect(portuguese.identifier(.bcp47) == "pt-PT")
    }

    @Test func switchingBetweenCohereAndAppleKeepsTheSameRegionalChoices() throws {
        let cohere = SpeechLanguages.choices(for: .cohere, availableLocales: appleLocales, userRegion: "BR")
        let apple = SpeechLanguages.choices(for: nil, availableLocales: appleLocales, userRegion: "BR")
        for language in ["en", "pt"] {
            let modelChoice = try #require(cohere.first { $0.language.languageCode?.identifier == language })
            let appleChoice = try #require(apple.first { $0.language.languageCode?.identifier == language })
            #expect(modelChoice == appleChoice)
            #expect(appleLocales.contains(modelChoice))
        }
        #expect(cohere.first { $0.language.languageCode?.identifier == "pt" }?.identifier(.bcp47) == "pt-BR")
    }

    @Test func cohereOffersSupportedLanguagesMissingFromAppleWithRegionalFallbacks() throws {
        let choices = SpeechLanguages.choices(for: .cohere, availableLocales: appleLocales, userRegion: nil)
        let greek = try #require(choices.first { $0.language.languageCode?.identifier == "el" })
        #expect(greek.identifier(.bcp47) == "el-GR")
        #expect(choices.count == LocalSpeechModel.cohere.languageCodes.count)
        #expect(Set(choices.compactMap { $0.language.languageCode?.identifier }) == Set(LocalSpeechModel.cohere.languageCodes))
    }

    @Test func swedishIsExcludedFromCohereAndPreservedForWhisper() throws {
        let cohere = SpeechLanguages.choices(for: .cohere, availableLocales: appleLocales, userRegion: nil)
        let whisper = SpeechLanguages.choices(for: .whisper, availableLocales: appleLocales, userRegion: nil)
        #expect(!cohere.contains { $0.language.languageCode?.identifier == "sv" })
        let swedish = try #require(whisper.first { $0.language.languageCode?.identifier == "sv" })
        #expect(swedish.identifier(.bcp47) == "sv-SE")
        #expect(appleLocales.contains(swedish))
    }

    @Test func whisperLanguagesMissingFromAppleHaveRegionalFallbacks() throws {
        let choices = SpeechLanguages.choices(for: .whisper, availableLocales: appleLocales, userRegion: nil)
        let afrikaans = try #require(choices.first { $0.language.languageCode?.identifier == "af" })
        #expect(afrikaans.region?.identifier == "ZA")
        #expect(choices.allSatisfy { $0.region != nil })
        #expect(Set(choices.compactMap { $0.language.languageCode?.identifier }).count == choices.count)
    }

    @Test func automaticModelsUseOnlyTheAvailableAppleLanguageChoices() {
        let apple = SpeechLanguages.choices(for: nil, availableLocales: appleLocales, userRegion: nil)
        #expect(SpeechLanguages.choices(for: .qwen, availableLocales: appleLocales, userRegion: nil) == apple)
        #expect(SpeechLanguages.choices(for: .redux, availableLocales: appleLocales, userRegion: nil) == apple)
        #expect(apple.allSatisfy(appleLocales.contains))
    }

    @Test func whisperLegacyLanguageCodesPreserveCanonicalAppleVariants() throws {
        let available = ["nb-NO", "jv-ID", "fil-PH"].map(Locale.init(identifier:))
        let choices = SpeechLanguages.choices(for: .whisper, availableLocales: available, userRegion: nil)
        for language in ["nb", "jv", "fil"] {
            let selected = try #require(choices.first { $0.language.languageCode?.identifier == language })
            #expect(available.contains(selected))
            #expect(choices.filter { $0.language.languageCode?.identifier == language }.count == 1)
        }
    }
}
