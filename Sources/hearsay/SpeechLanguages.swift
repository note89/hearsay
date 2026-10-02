import Foundation
import Transcription

/// One regional locale per language, preserving Apple's supported variants when possible.
enum SpeechLanguages {
    private static let preferredLocales = [
        "en": "en-US", "pt": "pt-PT", "sv": "sv-SE", "fr": "fr-FR", "de": "de-DE",
        "it": "it-IT", "es": "es-ES", "el": "el-GR", "nl": "nl-NL", "pl": "pl-PL",
        "zh": "zh-CN", "ja": "ja-JP", "ko": "ko-KR", "vi": "vi-VN", "ar": "ar-SA",
    ]

    static func choices(for model: LocalSpeechModel?, availableLocales: [Locale], userRegion: String?) -> [Locale] {
        let locales: [Locale]
        if let model, model.needsLocale {
            let supportedLanguages = Set(model.languageCodes.map { languageCode(of: Locale(identifier: $0)) })
            let supported = availableLocales.filter {
                supportedLanguages.contains(languageCode(of: $0))
            }
            let representedLanguages = Set(supported.map(languageCode))
            let missing = model.languageCodes.filter {
                !representedLanguages.contains(languageCode(of: Locale(identifier: $0)))
            }.map {
                Locale(identifier: preferredLocales[$0] ?? Locale.Language(identifier: $0).maximalIdentifier)
            }
            locales = supported + missing
        } else {
            locales = availableLocales
        }

        let byLanguage = Dictionary(grouping: locales, by: languageCode)
        return byLanguage.map { language, variants in
            let ordered = variants.sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
            if let userRegion, let regional = ordered.first(where: { $0.region?.identifier == userRegion }) {
                return regional
            }
            if let canonical = preferredLocales[language],
                let preferred = ordered.first(where: { $0.identifier(.bcp47) == canonical })
            {
                return preferred
            }
            return ordered[0]
        }
        .sorted { displayName(of: $0) < displayName(of: $1) }
    }

    private static func languageCode(of locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? locale.identifier
    }

    private static func displayName(of locale: Locale) -> String {
        Locale.current.localizedString(forLanguageCode: languageCode(of: locale)) ?? locale.identifier
    }
}
